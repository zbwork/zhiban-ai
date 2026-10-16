//go:build windows

package install

import (
	"bufio"
	"context"
	_ "embed"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"os"
	"os/user"
	"strings"
	"time"
	"unicode/utf16"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/operation"
)

//go:embed registration_worker.ps1
var registrationWorker string

const authorizationTimeout = 5 * time.Minute
const registrationWorkerLifetime = 45 * time.Minute

type registrationProcessResult struct {
	code int
	err  error
}

type windowsPackageRegistration struct {
	pipe   *os.File
	reader *bufio.Reader
	cancel context.CancelFunc
	done   chan struct{}
	result registrationProcessResult // published by closing done
}

func preparePackageRegistration(ctx context.Context, report *operation.Reporter, asset Asset, path, mode string) (packageRegistration, error) {
	if asset.PlatformName() != PlatformWindows || !asset.IsBundle() {
		return nil, nil
	}
	if !canElevate() {
		return nil, operation.Fail(installCode(asset.TargetID, "REQUIREMENTS_UNMET"), errors.New(IssueAdminRequired))
	}
	report.Stage(StageAuthorizing, true)
	registration, reason, err := startPackageRegistration(ctx, asset, path, mode)
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, operation.Fail(installCode(asset.TargetID, reason), err)
	}
	return registration, nil
}

func encodedPowerShell(script string) string {
	units := utf16.Encode([]rune(script))
	data := make([]byte, 2*len(units))
	for i, unit := range units {
		binary.LittleEndian.PutUint16(data[i*2:], unit)
	}
	return base64.StdEncoding.EncodeToString(data)
}

func packageRegistrationScript(asset Asset, path, mode, pipe, sid string) string {
	locks := make([]string, 0, len(asset.Sources))
	for _, source := range asset.Sources {
		if source.Layout == LayoutMSIX {
			locks = append(locks, fmt.Sprintf("@{size=%d;hash=%s}", source.Size, psQuote(source.SHA256)))
		}
	}
	update := ""
	if mode != ModeInstall {
		update = "-ForceUpdateFromAnyVersion"
	}
	return strings.NewReplacer(
		"__USER_SID__", psQuote(sid), "__PIPE_NAME__", psQuote(pipe),
		"__PACKAGE_PATH__", psQuote(path), "__SOURCE_LOCKS__", strings.Join(locks, ","),
		"__SIGNER__", psQuote(asset.SignerName), "__PACKAGE_NAME__", psQuote(asset.PackageName),
		"__PACKAGE_VERSION__", psQuote(asset.Version+"."), "__PACKAGE_ARCH__", psQuote(windowsPackageArch(asset.Arch)),
		"__UPDATE_FLAG__", update,
	).Replace(registrationWorker)
}

func startPackageRegistration(ctx context.Context, asset Asset, path, mode string) (*windowsPackageRegistration, string, error) {
	account, err := user.Current()
	if err != nil {
		return nil, "AUTHORIZATION_FAILED", err
	}
	pipeName, err := randomName("zhiban-msix-")
	if err != nil {
		return nil, "AUTHORIZATION_FAILED", err
	}
	script := packageRegistrationScript(asset, path, mode, pipeName, account.Uid)
	// EncodedCommand crosses both PowerShell and ShellExecute argument parsing
	// without interpreting a profile path as shell syntax.
	launch := "$ErrorActionPreference='Stop'; $env:PSModulePath=$PSHOME+'\\Modules'; try { $p = Start-Process -FilePath " + psQuote(powershellPath()) +
		" -Verb RunAs -ArgumentList " + psQuote("-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand "+encodedPowerShell(script)) +
		" -WindowStyle Hidden -PassThru -Wait; exit $p.ExitCode } catch { $e=$_.Exception; while ($e) { if ($e.PSObject.Properties['NativeErrorCode'] -and $e.NativeErrorCode -eq 1223) { exit 1223 }; $e=$e.InnerException }; exit 3 }"
	workerContext, cancel := context.WithTimeout(ctx, registrationWorkerLifetime)
	worker := &windowsPackageRegistration{cancel: cancel, done: make(chan struct{})}
	go func() {
		_, code, err := runPowerShell(workerContext, registrationWorkerLifetime, launch)
		worker.result = registrationProcessResult{code: code, err: err}
		close(worker.done)
	}()
	readyContext, readyCancel := context.WithTimeout(ctx, authorizationTimeout)
	defer readyCancel()
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-readyContext.Done():
			worker.Close()
			return nil, "AUTHORIZATION_TIMEOUT", readyContext.Err()
		case <-worker.done:
			worker.Close()
			reason := "AUTHORIZATION_FAILED"
			if worker.result.code == errorCancelled {
				reason = "AUTHORIZATION_CANCELLED"
			}
			return nil, reason, fmt.Errorf("authorization worker exited (%d): %v", worker.result.code, worker.result.err)
		case <-ticker.C:
			pipe, err := os.OpenFile(`\\.\pipe\`+pipeName, os.O_RDWR, 0)
			if err != nil {
				continue
			}
			worker.pipe, worker.reader = pipe, bufio.NewReader(pipe)
			line, err := worker.readLine(readyContext)
			if err != nil || line != "ready" {
				worker.Close()
				return nil, "AUTHORIZATION_FAILED", fmt.Errorf("authorization handshake failed: %v", err)
			}
			return worker, "", nil
		}
	}
}

func (w *windowsPackageRegistration) readLine(ctx context.Context) (string, error) {
	type response struct {
		line string
		err  error
	}
	result := make(chan response, 1)
	go func() {
		// No unbounded ReadString: the protocol has only short status messages.
		line, prefix, err := w.reader.ReadLine()
		if prefix {
			err = errors.New("oversized registration response")
		}
		result <- response{strings.TrimSpace(string(line)), err}
	}()
	select {
	case <-ctx.Done():
		_ = w.pipe.Close()
		return "", ctx.Err()
	case r := <-result:
		return r.line, r.err
	}
}

func (w *windowsPackageRegistration) Register(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, packageRegisterTimeout)
	defer cancel()
	if _, err := w.pipe.Write([]byte("install\n")); err != nil {
		return err
	}
	line, err := w.readLine(ctx)
	if err != nil {
		return err
	}
	if line != "ok" {
		return fmt.Errorf("package registration failed: %s", line)
	}
	return nil
}

func (w *windowsPackageRegistration) Close() {
	if w.pipe != nil {
		_ = w.pipe.Close()
		// Let the child release its package handle before scratch cleanup.
		select {
		case <-w.done:
		case <-time.After(2 * time.Second):
		}
	}
	// Closing the pipe releases the elevated worker's single pending read.
	w.cancel()
}

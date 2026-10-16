import { loadConfig } from './config.js';
import { buildApp } from './server/app.js';

const config = loadConfig();
const app = await buildApp(config);

let closing = false;
const shutdown = async (signal: string) => {
  if (closing) return;
  closing = true;
  app.log.info({ signal }, 'shutting down');
  await app.close();
  process.exit(0);
};
process.on('SIGTERM', () => void shutdown('SIGTERM'));
process.on('SIGINT', () => void shutdown('SIGINT'));

try {
  await app.listen({ host: config.host, port: config.port });
  app.log.info({ data_dir: config.dataDir, cordis_dir: config.cordisDir, model: config.defaultModel, max_processes: config.maxProcesses }, 'dsh-runtime listening');
} catch (err) {
  app.log.error({ err }, 'listen failed');
  process.exit(1);
}

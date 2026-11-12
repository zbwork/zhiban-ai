import { useEffect, useMemo, useState } from 'react'
import clsx from 'clsx'
import {
  AppWindow,
  AlertTriangle,
  AudioLines,
  BarChart3,
  Bolt,
  Box,
  Braces,
  Check,
  CheckCircle2,
  Clock3,
  Code2,
  Copy,
  File,
  Folder,
  Grid2X2,
  Image,
  Layers3,
  ListChecks,
  Package,
  Puzzle,
  Search,
  ShieldCheck,
  SlidersHorizontal,
  Tag,
  Table2,
  Type,
  Video,
  Workflow,
  Wrench,
} from 'lucide-react'
import { Input, InlineAlert } from '../components/ui'
import { EMPBlocks, type EMPBlock } from '../lib/api'

type EMPCategory = EMPBlock['category']
type EMPBlockTab = 'all' | EMPCategory
type ClientSupportLevel = 'rich' | 'timeline' | 'fallback' | 'not_wired'

type ClientSupport = {
  level: ClientSupportLevel
  label: string
  summary: string
  source: string
}

type EMPMessageExample = {
  event: string
  [key: string]: unknown
}

const CAT_ORDER: EMPCategory[] = ['content', 'interactive', 'process', 'artifact']

const CAT_LABEL: Record<EMPCategory, string> = {
  content: '内容',
  interactive: '交互',
  process: '过程',
  artifact: '产物',
}

const CAT_LONG_LABEL: Record<EMPCategory, string> = {
  content: '内容（文本/图表/图片）',
  interactive: '交互（表单/审批/按钮）',
  process: '过程（进度/思考/工具）',
  artifact: '产物（文件/卡片）',
}

const ICON_STYLE: Record<string, { icon: typeof Puzzle; bg: string; fg: string }> = {
  artifact: { icon: Package, bg: 'bg-[var(--color-icon-green-bg)]', fg: 'text-[var(--color-icon-green)]' },
  audio: { icon: AudioLines, bg: 'bg-[var(--color-icon-blue-bg)]', fg: 'text-[var(--color-icon-blue)]' },
  chart: { icon: BarChart3, bg: 'bg-[var(--color-icon-purple-bg)]', fg: 'text-[var(--color-icon-purple)]' },
  code: { icon: Code2, bg: 'bg-[var(--color-icon-orange-bg)]', fg: 'text-[var(--color-icon-orange)]' },
  file: { icon: Folder, bg: 'bg-[var(--color-icon-blue-bg)]', fg: 'text-[var(--color-icon-blue)]' },
  form: { icon: ListChecks, bg: 'bg-[var(--color-icon-green-bg)]', fg: 'text-[var(--color-icon-green)]' },
  image: { icon: Image, bg: 'bg-[var(--color-icon-red-bg)]', fg: 'text-[var(--color-icon-red)]' },
  markdown: { icon: Braces, bg: 'bg-[var(--color-icon-blue-bg)]', fg: 'text-[var(--color-icon-blue)]' },
  plain: { icon: Type, bg: 'bg-[var(--color-icon-green-bg)]', fg: 'text-[var(--color-icon-green)]' },
  table: { icon: Table2, bg: 'bg-[var(--color-icon-green-bg)]', fg: 'text-[var(--color-icon-green)]' },
  video: { icon: Video, bg: 'bg-[var(--color-icon-purple-bg)]', fg: 'text-[var(--color-icon-purple)]' },
  action: { icon: Bolt, bg: 'bg-[var(--color-icon-orange-bg)]', fg: 'text-[var(--color-icon-orange)]' },
  app_card: { icon: AppWindow, bg: 'bg-[var(--color-icon-purple-bg)]', fg: 'text-[var(--color-icon-purple)]' },
  approval: { icon: ShieldCheck, bg: 'bg-[var(--color-icon-green-bg)]', fg: 'text-[var(--color-icon-green)]' },
  confirm: { icon: CheckCircle2, bg: 'bg-[var(--color-icon-blue-bg)]', fg: 'text-[var(--color-icon-blue)]' },
  progress: { icon: Workflow, bg: 'bg-[var(--color-icon-blue-bg)]', fg: 'text-[var(--color-icon-blue)]' },
  tool_call: { icon: Wrench, bg: 'bg-[var(--color-icon-orange-bg)]', fg: 'text-[var(--color-icon-orange)]' },
  tool_result: { icon: Wrench, bg: 'bg-[var(--color-icon-green-bg)]', fg: 'text-[var(--color-icon-green)]' },
}

const CLIENT_SUPPORT: Record<string, ClientSupport> = {
  markdown: {
    level: 'rich',
    label: '富组件',
    summary: 'ChatMarkdownWidget 真渲染，支持 markdown/plain/text 内容。',
    source: 'EmpBlocksView: markdown/plain/text',
  },
  plain: {
    level: 'rich',
    label: '富组件',
    summary: '按文本类 block 进入 ChatMarkdownWidget，和 markdown 同一渲染路径。',
    source: 'EmpBlocksView: plain/text',
  },
  chart: {
    level: 'rich',
    label: '富组件',
    summary: '客户端读取 chart_kind；bar/line/area/pie/donut/scatter/radar/kpi 真渲染，复杂图走富 fallback。',
    source: 'EmpBlocksView: _ChartBlockView',
  },
  image: {
    level: 'rich',
    label: '富组件',
    summary: '图片走媒体卡片，支持网络图片预览和失败兜底。',
    source: 'EmpBlocksView: image -> _MediaBlockView',
  },
  video: {
    level: 'rich',
    label: '富组件',
    summary: 'video_player 真播放器；URL 缺失或初始化失败时退化为文件卡。',
    source: 'EmpBlocksView: _VideoPlayerView',
  },
  audio: {
    level: 'rich',
    label: '富组件',
    summary: 'audioplayers 真播放器；失败时退化为文件卡。',
    source: 'EmpBlocksView: _AudioPlayerView',
  },
  form: {
    level: 'rich',
    label: 'HITL',
    summary: 'awaiting_user 且上下文齐全时可提交；支持 text/select/date/file 等字段。',
    source: 'EmpBlocksView: _FormBlockView + /chat/respond',
  },
  approval: {
    level: 'rich',
    label: 'HITL',
    summary: '审批卡支持同意/拒绝，拒绝 reason 由客户端交互收集。',
    source: 'EmpBlocksView: _ApprovalBlockView(approval)',
  },
  action: {
    level: 'rich',
    label: 'HITL',
    summary: '操作按钮点击后走 action response；action_bar 是同一路兼容别名。',
    source: 'EmpBlocksView: action/action_bar',
  },
  confirm: {
    level: 'rich',
    label: 'HITL',
    summary: '二次确认走 confirm response，payload 是 confirmed:true/false，不复用 approval。',
    source: 'EmpBlocksView: _ApprovalBlockView(confirm)',
  },
  progress: {
    level: 'rich',
    label: '富组件',
    summary: '进度组件按 percent/progress 展示进度条与步骤信息。',
    source: 'EmpBlocksView: _ProgressBlockView',
  },
  source: {
    level: 'rich',
    label: '富组件',
    summary: '引用来源卡支持 title/url/items/sources，并可打开外链。',
    source: 'EmpBlocksView: source/citation',
  },
  artifact: {
    level: 'rich',
    label: '富组件',
    summary: '产物卡按 artifact_kind/kind/name/url 渲染，展示侧不走 respond。',
    source: 'EmpBlocksView: _ArtifactBlockView',
  },
  file: {
    level: 'rich',
    label: '富组件',
    summary: '文件卡展示附件名称、类型和打开入口。',
    source: 'EmpBlocksView: file -> _MediaBlockView',
  },
  app_card: {
    level: 'rich',
    label: '富组件',
    summary: '应用入口卡片展示图标、标题和摘要，业务跳转由调用方承接。',
    source: 'EmpBlocksView: _AppCardBlockView',
  },
  code: {
    level: 'rich',
    label: '富组件',
    summary: '代码块支持 language/lang/source/text/content 字段。',
    source: 'EmpBlocksView: _CodeBlockView',
  },
  table: {
    level: 'rich',
    label: '富组件',
    summary: '表格支持 headers/columns/rows/data，宽表可横向滚动。',
    source: 'EmpBlocksView: _TableBlockView',
  },
  plan: {
    level: 'rich',
    label: '富组件',
    summary: '计划步骤按 steps/items 顺序展示。',
    source: 'EmpBlocksView: _PlanBlockView',
  },
  error: {
    level: 'rich',
    label: '富组件',
    summary: '内联错误卡展示安全错误文案，不透传 runtime 原始错误。',
    source: 'EmpBlocksView: _InlineErrorBlockView',
  },
  tool_result: {
    level: 'rich',
    label: '有内容时渲染',
    summary: '终态 tool_result 只有 result/text 非空时渲染卡片；空结果会隐藏。',
    source: 'EmpBlocksView: _ToolResultBlockView',
  },
  tool_call: {
    level: 'timeline',
    label: '时间线事件',
    summary: '实际主路径是 SSE timeline 过程事件；不建议作为 completed.blocks 里的终态富卡。',
    source: 'chat_providers.dart: eventType=tool_call',
  },
  reasoning: {
    level: 'timeline',
    label: '时间线事件',
    summary: '实际主路径是 SSE reasoning 事件写入 timeline/reasoningContent；终态 block 仅兜底。',
    source: 'chat_providers.dart: eventType=reasoning',
  },
  thought: {
    level: 'fallback',
    label: '兜底展示',
    summary: '历史 reasoning 别名；EmpBlocksView 没有独立 switch，最终气泡只走文本兜底。',
    source: 'empBlocksToReadableText: unknown fallback',
  },
  suggestion: {
    level: 'fallback',
    label: '兜底展示',
    summary: '设计里是推荐回复 chips，但当前客户端真实 chips 未接入，最终气泡走文本兜底。',
    source: 'agent-bus-client-contract: suggestion defer',
  },
  orchestration: {
    level: 'not_wired',
    label: '未接入',
    summary: 'OrchestrationBlock 文件存在，但未接入消息渲染链路；最终气泡不会真渲染编排卡。',
    source: 'F09 PR7-D follow-up: standalone widget',
  },
}

const EMP_MESSAGE_EXAMPLES: Record<string, EMPMessageExample> = {
  markdown: {
    event: 'message.completed',
    blocks: [
      {
        id: 'blk_markdown_001',
        type: 'markdown',
        text: '## 合同摘要\n- 付款周期：30 天\n- 风险提示：缺少违约责任条款',
      },
    ],
  },
  plain: {
    event: 'message.completed',
    blocks: [
      {
        id: 'blk_plain_001',
        type: 'plain',
        text: '已为你整理 3 条待办事项。',
      },
    ],
  },
  code: {
    event: 'message.completed',
    blocks: [
      {
        id: 'blk_code_001',
        type: 'code',
        language: 'python',
        text: "from zhiban_agent_sdk.zap import emp\n\nblocks = [emp.markdown('完成')]",
        filename: 'zap_component_demo.py',
      },
    ],
  },
  chart: {
    event: 'message.completed',
    blocks: [
      {
        id: 'blk_chart_001',
        type: 'chart',
        chart_kind: 'bar',
        title: '近 6 个月营收',
        summary: 'Q2 起恢复增长，6 月达到本年度峰值。',
        insights: ['6 月营收 640 万', '环比 +15.6%'],
        unit: '万元',
        source: '财务系统',
        updated_at: '2 分钟前',
        data: [
          { label: '4月', value: 420 },
          { label: '5月', value: 510 },
          { label: '6月', value: 640 },
        ],
      },
    ],
  },
  table: {
    event: 'message.completed',
    blocks: [
      {
        id: 'blk_table_001',
        type: 'table',
        title: '部门工时统计',
        headers: ['部门', '成员数', '总工时'],
        rows: [
          ['产品', 8, 1280],
          ['技术', 24, 4032],
        ],
      },
    ],
  },
  image: {
    event: 'message.completed',
    blocks: [
      {
        id: 'blk_image_001',
        type: 'image',
        name: '流程截图.png',
        url: 'https://example.com/files/process.png',
        summary: '审批流程截图',
      },
    ],
  },
  video: {
    event: 'message.completed',
    blocks: [
      {
        id: 'blk_video_001',
        type: 'video',
        name: '会议纪要.mp4',
        url: 'https://example.com/files/meeting.mp4',
        mime_type: 'video/mp4',
      },
    ],
  },
  audio: {
    event: 'message.completed',
    blocks: [
      {
        id: 'blk_audio_001',
        type: 'audio',
        name: '客户访谈录音.mp3',
        url: 'https://example.com/files/interview.mp3',
        mime_type: 'audio/mpeg',
      },
    ],
  },
  form: {
    event: 'message.awaiting_user',
    message_id: 'msg_agent_001',
    awaiting_block_id: 'blk_form_001',
    blocks: [
      {
        id: 'blk_form_001',
        type: 'form',
        title: '补充报销信息',
        description: '请确认金额和费用类型。',
        fields: [
          { name: 'amount', label: '金额', type: 'number', required: true },
          { name: 'category', label: '费用类型', type: 'select', options: ['差旅', '办公', '招待'] },
          { name: 'confirmed', label: '我已确认', type: 'checkbox', required: true },
        ],
      },
    ],
  },
  approval: {
    event: 'message.awaiting_user',
    message_id: 'msg_agent_001',
    awaiting_block_id: 'blk_approval_001',
    blocks: [
      {
        id: 'blk_approval_001',
        type: 'approval',
        title: '审批合同用印申请',
        summary: '合同金额 86 万元，需法务确认后提交用印。',
      },
    ],
  },
  confirm: {
    event: 'message.awaiting_user',
    message_id: 'msg_agent_001',
    awaiting_block_id: 'blk_confirm_001',
    blocks: [
      {
        id: 'blk_confirm_001',
        type: 'confirm',
        title: '确认提交采购申请',
        summary: '提交后将进入部门负责人审批。',
        action_id: 'confirm_purchase_request',
      },
    ],
  },
  action: {
    event: 'message.awaiting_user',
    message_id: 'msg_agent_001',
    awaiting_block_id: 'blk_action_001',
    blocks: [
      {
        id: 'blk_action_001',
        type: 'action',
        title: '选择下一步处理方式',
        actions: [
          { id: 'create_task', label: '创建任务' },
          { id: 'send_notice', label: '发送通知' },
        ],
      },
    ],
  },
  app_card: {
    event: 'message.completed',
    blocks: [
      {
        id: 'blk_app_card_001',
        type: 'app_card',
        app_id: 'crm',
        title: '客户管理',
        subtitle: '打开客户详情和跟进记录',
        icon: 'briefcase',
      },
    ],
  },
  source: {
    event: 'message.completed',
    blocks: [
      {
        id: 'blk_source_001',
        type: 'source',
        title: '参考资料',
        items: [
          {
            title: '合同审批制度',
            url: 'https://example.com/docs/contract-policy',
            snippet: '金额超过 50 万元需二级审批。',
          },
        ],
      },
    ],
  },
  artifact: {
    event: 'message.completed',
    blocks: [
      {
        id: 'blk_artifact_001',
        type: 'artifact',
        artifact_kind: 'document',
        name: '合同风险审查报告.docx',
        url: 'https://example.com/files/contract-review.docx',
      },
    ],
  },
  file: {
    event: 'message.completed',
    blocks: [
      {
        id: 'blk_file_001',
        type: 'file',
        name: '审批材料.zip',
        url: 'https://example.com/files/approval.zip',
        size: 2480000,
      },
    ],
  },
  progress: {
    event: 'message.completed',
    blocks: [
      {
        id: 'blk_progress_001',
        type: 'progress',
        title: '正在生成报告',
        percent: 70,
        steps: [
          { label: '读取数据', status: 'done' },
          { label: '生成图表', status: 'running' },
          { label: '整理结论', status: 'pending' },
        ],
      },
    ],
  },
  tool_call: {
    event: 'message.tool_call',
    tool_call_id: 'call_kb_search_001',
    tool_name: 'kb.search',
    tool_status: 'running',
    tool_args: {
      query: '合同付款条款风险',
    },
  },
  tool_result: {
    event: 'message.completed',
    blocks: [
      {
        id: 'blk_tool_result_001',
        type: 'tool_result',
        tool_name: 'kb.search',
        status: 'done',
        result: '检索到 3 条相关制度，最高匹配度 0.91。',
      },
    ],
  },
  reasoning: {
    event: 'message.reasoning',
    text: '先识别合同金额、付款周期和违约条款，再判断是否需要升级审批。',
  },
  thought: {
    event: 'message.completed',
    blocks: [
      {
        id: 'blk_thought_001',
        type: 'thought',
        text: '历史 reasoning 别名；客户端当前只做文本兜底。',
      },
    ],
  },
  plan: {
    event: 'message.completed',
    blocks: [
      {
        id: 'blk_plan_001',
        type: 'plan',
        title: '处理计划',
        steps: [
          { title: '读取合同', status: 'done' },
          { title: '识别风险', status: 'running' },
          { title: '输出建议', status: 'pending' },
        ],
      },
    ],
  },
  error: {
    event: 'message.completed',
    blocks: [
      {
        id: 'blk_error_001',
        type: 'error',
        title: '无法生成报告',
        message: '数据源暂时不可用，请稍后重试。',
        error_code: 'data_source_unavailable',
      },
    ],
  },
  suggestion: {
    event: 'message.completed',
    blocks: [
      {
        id: 'blk_suggestion_001',
        type: 'suggestion',
        items: ['继续分析风险', '生成审批摘要', '导出报告'],
      },
    ],
  },
  orchestration: {
    event: 'message.completed',
    blocks: [
      {
        id: 'blk_orchestration_001',
        type: 'orchestration',
        title: '协作编排',
        agents: ['法务助手', '财务助手'],
        current_step: '法务复核',
      },
    ],
  },
}

export function EMPBlockList() {
  const [items, setItems] = useState<EMPBlock[]>([])
  const [err, setErr] = useState('')
  const [selected, setSelected] = useState<EMPBlock | null>(null)
  const [activeTab, setActiveTab] = useState<EMPBlockTab>('all')
  const [query, setQuery] = useState('')
  const [attentionOnly, setAttentionOnly] = useState(false)

  useEffect(() => {
    EMPBlocks.list()
      .then((r) => {
        const rows = r.items || []
        setItems(rows)
        setSelected((current) => current || rows[0] || null)
      })
      .catch((e: Error) => setErr(e.message))
  }, [])

  const grouped = useMemo(() => {
    const g: Record<EMPCategory, EMPBlock[]> = { content: [], interactive: [], process: [], artifact: [] }
    items.forEach((b) => {
      g[b.category]?.push(b)
    })
    return g
  }, [items])

  const latestClientVersion = useMemo(() => {
    const versions = items.map((b) => b.min_client_version).filter(Boolean) as string[]
    return versions.sort(compareVersionDesc)[0] || '无要求'
  }, [items])

  const latestUpdatedAt = useMemo(() => {
    const timestamps = items
      .map((b) => b.updated_at)
      .filter(Boolean)
      .sort()
    return timestamps[timestamps.length - 1] || ''
  }, [items])

  const visibleBlocks = useMemo(() => {
    const source = activeTab === 'all' ? items : grouped[activeTab]
    const keyword = query.trim().toLowerCase()
    const scoped = attentionOnly ? source.filter((b) => clientSupportFor(b).level !== 'rich') : source
    if (!keyword) return scoped
    return scoped.filter((b) =>
      [b.name, b.code, b.description, CAT_LONG_LABEL[b.category], clientSupportFor(b).label, clientSupportFor(b).summary]
        .filter(Boolean)
        .some((v) => String(v).toLowerCase().includes(keyword))
    )
  }, [activeTab, attentionOnly, grouped, items, query])

  const displayedSelected = selected && visibleBlocks.some((b) => b.id === selected.id)
    ? selected
    : visibleBlocks[0] || null

  function handleTabChange(next: EMPBlockTab) {
    setActiveTab(next)
    setSelected((current) => {
      if (next === 'all') return current
      return current?.category === next ? current : grouped[next][0] || null
    })
  }

  return (
    <div className="rounded-2xl border border-[var(--color-line)] bg-white/90 p-6 shadow-[0_18px_70px_rgba(15,107,255,0.08)]">
      <header className="mb-7 flex flex-col gap-6">
        <div className="flex items-start gap-4">
          <div className="grid h-14 w-14 shrink-0 place-items-center rounded-xl border border-[var(--color-brand-line)] bg-[var(--color-brand-soft)] text-[var(--color-brand)] shadow-[0_10px_24px_rgba(15,107,255,0.12)]">
            <Box size={30} />
          </div>
          <div className="min-w-0">
            <h1 className="text-[28px] font-semibold leading-tight text-[var(--color-text)]">EMP 协议管理</h1>
            <p className="mt-1 text-[14px] text-[var(--color-text-sub)]">
              知办AI Message Protocol 共注册 {items.length} 种 Block 类型，按 4 大类组织。
            </p>
          </div>
        </div>

        <div className="grid w-full max-w-[720px] grid-cols-2 overflow-hidden rounded-xl border border-[var(--color-line)] bg-white shadow-[0_10px_30px_rgba(15,23,42,0.04)] md:grid-cols-4">
          <Metric icon={Box} label="总类型数" value={`${items.length} 种`} />
          <Metric icon={Layers3} label="大类分组" value={`${CAT_ORDER.length} 类`} />
          <Metric icon={Tag} label="最新版本" value={latestClientVersion === '无要求' ? latestClientVersion : `v${latestClientVersion}`} />
          <Metric icon={Clock3} label="更新时间" value={formatDate(latestUpdatedAt)} />
        </div>
      </header>

      {err && (
        <div className="mb-4">
          <InlineAlert tone="danger">{err}</InlineAlert>
        </div>
      )}

      <div className="grid grid-cols-1 gap-6 xl:grid-cols-[minmax(0,1fr)_430px]">
        <section className="min-w-0">
          <div className="mb-4 flex flex-col gap-3 border-b border-[var(--color-line-soft)] pb-4 lg:flex-row lg:items-center lg:justify-between">
            <div className="flex max-w-full flex-nowrap gap-2 overflow-x-auto pb-1">
              <CategoryTab active={activeTab === 'all'} label="全部" count={items.length} onClick={() => handleTabChange('all')} />
              {CAT_ORDER.map((cat) => (
                <CategoryTab
                  key={cat}
                  active={activeTab === cat}
                  label={CAT_LABEL[cat]}
                  count={grouped[cat].length}
                  onClick={() => handleTabChange(cat)}
                />
              ))}
            </div>
            <div className="flex items-center gap-2">
              <label className="relative block w-full min-w-[220px] lg:w-[280px]">
                <Search size={16} className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-[var(--color-text-mute)]" />
                <Input
                  value={query}
                  onChange={(e) => setQuery(e.target.value)}
                  placeholder="搜索 Block 类型..."
                  className="pl-9"
                />
              </label>
              <button
                type="button"
                onClick={() => setAttentionOnly((v) => !v)}
                className={clsx(
                  'grid h-9 w-9 shrink-0 place-items-center rounded-md border transition',
                  attentionOnly
                    ? 'border-[var(--color-brand)] bg-[var(--color-brand-soft)] text-[var(--color-brand)]'
                    : 'border-[var(--color-line)] bg-white text-[var(--color-text-sub)] hover:bg-[var(--color-control-hover)] hover:text-[var(--color-brand)]'
                )}
                title="仅看需关注项"
              >
                <SlidersHorizontal size={17} />
              </button>
            </div>
          </div>

          <div className="mb-3 flex items-center gap-2 text-[14px] font-semibold text-[var(--color-text)]">
            <Grid2X2 size={17} className="text-[var(--color-text-sub)]" />
            <span>{activeTab === 'all' ? '全部类型' : CAT_LONG_LABEL[activeTab]}</span>
            <span className="text-[var(--color-text-mute)]">·</span>
            <span>{visibleBlocks.length} 种</span>
          </div>

          {visibleBlocks.length > 0 ? (
            <div className="grid grid-cols-1 gap-2.5 lg:grid-cols-2">
              {visibleBlocks.map((block) => (
                <EMPCard
                  key={`${block.code}-${block.version}`}
                  block={block}
                  active={displayedSelected?.id === block.id}
                  onClick={() => setSelected(block)}
                />
              ))}
            </div>
          ) : (
            <div className="rounded-xl border border-dashed border-[var(--color-line)] bg-[var(--color-bg-sub)] px-5 py-12 text-center text-[13px] text-[var(--color-text-sub)]">
              暂无匹配的 EMP Block
            </div>
          )}
        </section>

        <EMPDetail block={displayedSelected} />
      </div>
    </div>
  )
}

function Metric({ icon: Icon, label, value }: { icon: typeof Box; label: string; value: string }) {
  return (
    <div className="flex items-center gap-3 border-b border-r border-[var(--color-line-soft)] px-4 py-3 last:border-r-0 md:border-b-0">
      <span className="grid h-8 w-8 shrink-0 place-items-center rounded-lg bg-[var(--color-brand-soft)] text-[var(--color-brand)]">
        <Icon size={18} />
      </span>
      <span className="min-w-0">
        <span className="block text-[12px] text-[var(--color-text-mute)]">{label}</span>
        <span className="block truncate text-[14px] font-semibold text-[var(--color-text)]">{value}</span>
      </span>
    </div>
  )
}

function CategoryTab({ active, label, count, onClick }: { active: boolean; label: string; count: number; onClick: () => void }) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={clsx(
        'h-9 min-w-[92px] shrink-0 rounded-lg px-4 text-[13px] font-medium transition',
        active
          ? 'bg-[var(--color-brand)] text-white shadow-[0_8px_18px_rgba(15,107,255,0.24)]'
          : 'bg-[var(--color-bg-sub)] text-[var(--color-text-sub)] hover:bg-[var(--color-brand-soft)] hover:text-[var(--color-brand)]'
      )}
    >
      {label} <span className={active ? 'text-white/90' : 'text-[var(--color-text-mute)]'}>{count}</span>
    </button>
  )
}

function EMPCard({ block, active, onClick }: { block: EMPBlock; active: boolean; onClick: () => void }) {
  const style = iconStyleFor(block)
  const Icon = style.icon
  const support = clientSupportFor(block)
  return (
    <button
      type="button"
      onClick={onClick}
      className={clsx(
        'group relative flex min-h-[92px] items-center gap-4 rounded-xl border bg-white px-4 py-3 text-left transition',
        active
          ? 'border-[var(--color-brand)] shadow-[0_10px_28px_rgba(15,107,255,0.14)]'
          : 'border-[var(--color-line)] shadow-[0_6px_20px_rgba(15,23,42,0.03)] hover:border-[var(--color-brand-line)] hover:shadow-[0_10px_26px_rgba(15,107,255,0.08)]'
      )}
    >
      <span className={clsx('grid h-12 w-12 shrink-0 place-items-center rounded-xl', style.bg, style.fg)}>
        <Icon size={24} />
      </span>
      <span className="min-w-0 flex-1">
        <span className="flex items-center gap-2">
          <span className="truncate text-[14px] font-semibold text-[var(--color-text)]">{block.name}</span>
          <span className="rounded-md bg-[var(--color-bg-sub)] px-1.5 py-0.5 font-mono text-[10px] text-[var(--color-text-mute)]">v{block.version}</span>
        </span>
        <span className="mt-0.5 block truncate font-mono text-[12px] text-[var(--color-text-mute)]">{block.code}</span>
        {block.description && <span className="mt-1 block truncate text-[12px] text-[var(--color-text-sub)]">{block.description}</span>}
        <span className="mt-2 flex items-center gap-2">
          <StatusPill status={block.status} />
          <SupportPill support={support} />
          {block.min_client_version && <span className="rounded-md bg-[var(--color-bg-sub)] px-1.5 py-0.5 text-[10px] text-[var(--color-text-mute)]">&gt;={block.min_client_version}</span>}
        </span>
      </span>
      {active && (
        <span className="absolute right-3 top-3 grid h-5 w-5 place-items-center rounded-full bg-[var(--color-brand)] text-white">
          <Check size={13} />
        </span>
      )}
    </button>
  )
}

function EMPDetail({ block }: { block: EMPBlock | null }) {
  if (!block) {
    return (
      <aside className="rounded-xl border border-[var(--color-line)] bg-white p-8 text-center text-[13px] text-[var(--color-text-sub)] shadow-[0_12px_40px_rgba(15,23,42,0.06)]">
        点击左侧 Block 查看 schema
      </aside>
    )
  }

  const style = iconStyleFor(block)
  const Icon = style.icon
  const support = clientSupportFor(block)
  const schema = JSON.stringify(block.json_schema || {}, null, 2)
  const example = messageExampleFor(block)
  const exampleJson = JSON.stringify(example, null, 2)

  return (
    <aside className="sticky top-4 self-start overflow-hidden rounded-xl border border-[var(--color-line)] bg-white shadow-[0_18px_52px_rgba(15,23,42,0.08)]">
      <div className="p-6">
        <div className="mb-7 flex items-start justify-between gap-4">
          <div className="flex min-w-0 items-center gap-4">
            <span className={clsx('grid h-11 w-11 shrink-0 place-items-center rounded-xl', style.bg, style.fg)}>
              <Icon size={24} />
            </span>
            <div className="min-w-0">
              <h2 className="truncate text-[18px] font-semibold text-[var(--color-text)]">{block.name}</h2>
              <p className="mt-1 font-mono text-[12px] text-[var(--color-text-mute)]">{block.code} · v{block.version}</p>
            </div>
          </div>
          <div className="flex shrink-0 flex-col items-end gap-2">
            <StatusPill status={block.status} size="md" />
            <SupportPill support={support} size="md" />
          </div>
        </div>

        <dl className="mb-5 grid grid-cols-[140px_minmax(0,1fr)] gap-x-5 gap-y-4 text-[13px]">
          <DetailLabel icon={Layers3}>分类</DetailLabel>
          <dd className="font-medium text-[var(--color-text)]">{block.category}</dd>
          <DetailLabel icon={CheckCircle2}>注册状态</DetailLabel>
          <dd><StatusPill status={block.status} /></dd>
          <DetailLabel icon={supportIconFor(support)}>客户端实现</DetailLabel>
          <dd>
            <SupportPill support={support} />
          </dd>
          <DetailLabel icon={File}>降级目标</DetailLabel>
          <dd className="font-medium text-[var(--color-text)]">{block.fallback_block_type || '无'}</dd>
          <DetailLabel icon={Clock3}>客户端最低版本</DetailLabel>
          <dd className="font-medium text-[var(--color-text)]">{block.min_client_version || '无要求'}</dd>
        </dl>

        <div className="mb-6 rounded-xl border border-[var(--color-line-soft)] bg-[var(--color-bg-sub)] px-4 py-3">
          <div className="text-[12px] font-semibold text-[var(--color-text)]">实际代码对照</div>
          <p className="mt-1 text-[12px] leading-relaxed text-[var(--color-text-sub)]">{support.summary}</p>
          <p className="mt-2 font-mono text-[11px] text-[var(--color-text-mute)]">{support.source}</p>
        </div>

        {block.description && (
          <div className="mb-6">
            <div className="text-[14px] font-semibold text-[var(--color-text)]">{block.description}</div>
            <div className="mt-2 h-0.5 w-8 rounded-full bg-[var(--color-brand)]" />
          </div>
        )}

        <div className="mb-6">
          <div className="mb-2 flex items-center justify-between gap-3">
            <div>
              <div className="text-[13px] font-semibold text-[var(--color-text)]">消息示例</div>
              <p className="mt-1 text-[12px] leading-relaxed text-[var(--color-text-sub)]">
                {exampleHintFor(example)}
              </p>
            </div>
          </div>
          <JsonCodeBlock code={exampleJson} copyTitle="复制消息示例" maxHeightClass="max-h-[220px]" />
        </div>

        <div className="mb-2 text-[12px] font-semibold uppercase text-[var(--color-text-mute)]">JSON Schema</div>
        <JsonCodeBlock code={schema} copyTitle="复制 JSON Schema" maxHeightClass="max-h-[260px]" />
      </div>
      <div className="border-t border-[var(--color-line-soft)] bg-[var(--color-bg-sub)] px-6 py-4 text-[12px] text-[var(--color-text-mute)]">
        <span className="inline-flex items-center gap-2">
          <Clock3 size={15} />
          更新时间：{formatDateTime(block.updated_at)}
        </span>
      </div>
    </aside>
  )
}

function JsonCodeBlock({
  code,
  copyTitle,
  maxHeightClass,
}: {
  code: string
  copyTitle: string
  maxHeightClass: string
}) {
  const lines = code.split('\n')
  return (
    <div className="relative overflow-hidden rounded-xl border border-[var(--color-line)] bg-[var(--color-bg-sub)]">
      <button
        type="button"
        className="absolute right-3 top-3 grid h-7 w-7 place-items-center rounded-md text-[var(--color-text-mute)] transition hover:bg-white hover:text-[var(--color-brand)]"
        onClick={() => navigator.clipboard?.writeText(code)}
        title={copyTitle}
      >
        <Copy size={16} />
      </button>
      <pre className={clsx('overflow-auto py-4 pl-4 pr-12 font-mono text-[12px] leading-6 text-[var(--color-brand)]', maxHeightClass)}>
        {lines.map((line, index) => (
          <span key={index} className="grid grid-cols-[28px_minmax(0,1fr)] gap-3">
            <span className="select-none text-right text-[var(--color-text-mute)]">{index + 1}</span>
            <code className="whitespace-pre text-[var(--color-brand)]">{line || ' '}</code>
          </span>
        ))}
      </pre>
    </div>
  )
}

function DetailLabel({ icon: Icon, children }: { icon: typeof Box; children: string }) {
  return (
    <dt className="flex items-center gap-2 text-[var(--color-text-mute)]">
      <Icon size={15} />
      <span>{children}</span>
    </dt>
  )
}

function StatusPill({ status, size = 'sm' }: { status: string; size?: 'sm' | 'md' }) {
  const map: Record<string, string> = {
    stable: 'bg-[var(--color-success-bg)] text-[var(--color-success)] border-[var(--color-success-bg)]',
    draft: 'bg-[var(--color-warn-bg)] text-[var(--color-warn)] border-[var(--color-warn-bg)]',
    deprecated: 'bg-[var(--color-danger-bg)] text-[var(--color-danger)] border-[var(--color-danger-bg)]',
  }
  return (
    <span className={clsx('inline-flex items-center rounded-md border font-medium', size === 'md' ? 'px-2.5 py-1 text-[12px]' : 'px-2 py-0.5 text-[11px]', map[status] || map.draft)}>
      {status}
    </span>
  )
}

function SupportPill({ support, size = 'sm' }: { support: ClientSupport; size?: 'sm' | 'md' }) {
  const map: Record<ClientSupportLevel, string> = {
    rich: 'bg-[var(--color-success-bg)] text-[var(--color-success)] border-[var(--color-success-bg)]',
    timeline: 'bg-[var(--color-info-bg)] text-[var(--color-info)] border-[var(--color-info-bg)]',
    fallback: 'bg-[var(--color-warn-bg)] text-[var(--color-warn)] border-[var(--color-warn-bg)]',
    not_wired: 'bg-[var(--color-danger-bg)] text-[var(--color-danger)] border-[var(--color-danger-bg)]',
  }
  return (
    <span className={clsx('inline-flex items-center rounded-md border font-medium', size === 'md' ? 'px-2.5 py-1 text-[12px]' : 'px-2 py-0.5 text-[11px]', map[support.level])}>
      {support.label}
    </span>
  )
}

function iconStyleFor(block: EMPBlock) {
  return ICON_STYLE[block.code] || ICON_STYLE[block.category] || {
    icon: Puzzle,
    bg: 'bg-[var(--color-brand-soft)]',
    fg: 'text-[var(--color-brand)]',
  }
}

function clientSupportFor(block: EMPBlock): ClientSupport {
  return CLIENT_SUPPORT[block.code] || {
    level: 'fallback',
    label: '兜底展示',
    summary: '当前客户端没有专用 switch；会按 unknown block 走 readable text fallback。',
    source: 'EmpBlocksView: default -> empBlocksToReadableText',
  }
}

function messageExampleFor(block: EMPBlock): EMPMessageExample {
  return EMP_MESSAGE_EXAMPLES[block.code] || {
    event: 'message.completed',
    blocks: [
      {
        id: `blk_${block.code}_001`,
        type: block.code,
        ...samplePayloadFromSchema(block.json_schema),
      },
    ],
  }
}

function samplePayloadFromSchema(schema?: Record<string, unknown>) {
  const properties = schema?.properties
  if (!properties || typeof properties !== 'object' || Array.isArray(properties)) return { text: '示例内容' }
  const out: Record<string, unknown> = {}
  Object.entries(properties as Record<string, { type?: unknown }>).slice(0, 6).forEach(([key, value]) => {
    if (key === 'type' || key === 'id') return
    out[key] = sampleValueForProperty(key, typeof value?.type === 'string' ? value.type : '')
  })
  return Object.keys(out).length > 0 ? out : { text: '示例内容' }
}

function sampleValueForProperty(key: string, type: string) {
  if (key.includes('url')) return 'https://example.com/resource'
  if (key.includes('title')) return '示例标题'
  if (key.includes('summary') || key.includes('description')) return '示例说明'
  if (key.includes('name')) return '示例名称'
  if (key.includes('action')) return 'demo_action'
  if (type === 'array') return []
  if (type === 'object') return {}
  if (type === 'number' || type === 'integer') return 1
  if (type === 'boolean') return true
  return '示例内容'
}

function exampleHintFor(example: EMPMessageExample) {
  if (example.event === 'message.awaiting_user') {
    return 'HITL 类型在等待用户时随 message.awaiting_user 下发；awaiting_block_id 指向需要响应的 block。'
  }
  if (example.event.startsWith('message.') && !Array.isArray(example.blocks)) {
    return '过程类主路径走 SSE timeline 事件；这里展示客户端真实消费的事件字段。'
  }
  return '展示型类型通常放在 message.completed.blocks 中；客户端终态气泡按 type 渲染或兜底展示。'
}

function supportIconFor(support: ClientSupport) {
  if (support.level === 'rich') return CheckCircle2
  if (support.level === 'timeline') return Clock3
  return AlertTriangle
}

function compareVersionDesc(a: string, b: string) {
  const pa = a.split('.').map((v) => Number(v) || 0)
  const pb = b.split('.').map((v) => Number(v) || 0)
  for (let i = 0; i < Math.max(pa.length, pb.length); i += 1) {
    const diff = (pb[i] || 0) - (pa[i] || 0)
    if (diff !== 0) return diff
  }
  return 0
}

function formatDate(value?: string) {
  if (!value) return '暂无'
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return value.slice(0, 10)
  return date.toISOString().slice(0, 10)
}

function formatDateTime(value?: string) {
  if (!value) return '暂无'
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return value
  const yyyy = date.getFullYear()
  const mm = String(date.getMonth() + 1).padStart(2, '0')
  const dd = String(date.getDate()).padStart(2, '0')
  const hh = String(date.getHours()).padStart(2, '0')
  const min = String(date.getMinutes()).padStart(2, '0')
  return `${yyyy}-${mm}-${dd} ${hh}:${min}`
}

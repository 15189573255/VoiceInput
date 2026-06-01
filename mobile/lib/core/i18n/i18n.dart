import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppLocale { zh, en }

extension AppLocaleX on AppLocale {
  String get code => this == AppLocale.en ? 'en' : 'zh';
  String get label => this == AppLocale.en ? 'English' : '中文';
}

/// App-wide translator. ChangeNotifier so MaterialApp / specific widgets can
/// rebuild when the user switches language. Dictionary is keyed by stable
/// dot-paths; missing keys fall back to the key itself so debugging surfaces
/// them quickly.
class I18n extends ChangeNotifier {
  static final I18n instance = I18n._();
  I18n._();

  static const _kPrefLocale = 'voiceinput.locale';

  AppLocale _locale = AppLocale.zh;
  AppLocale get locale => _locale;

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    final v = p.getString(_kPrefLocale);
    if (v == 'en') {
      _locale = AppLocale.en;
    } else {
      _locale = AppLocale.zh;
    }
    notifyListeners();
  }

  Future<void> setLocale(AppLocale l) async {
    if (_locale == l) return;
    _locale = l;
    final p = await SharedPreferences.getInstance();
    await p.setString(_kPrefLocale, l.code);
    notifyListeners();
  }

  String t(String key, [List<Object>? args]) {
    final entry = _dict[key];
    if (entry == null) return key;
    var s = entry[_locale] ?? entry[AppLocale.en] ?? key;
    if (args != null) {
      for (var i = 0; i < args.length; i++) {
        s = s.replaceAll('{$i}', args[i].toString());
      }
    }
    return s;
  }
}

/// Convenience top-level wrappers — every widget can just call `tr('...')`
/// without holding an I18n reference.
String tr(String key, [List<Object>? args]) => I18n.instance.t(key, args);

const Map<String, Map<AppLocale, String>> _dict = {
  // App-level
  'app.title':            {AppLocale.zh: 'VoiceInput',          AppLocale.en: 'VoiceInput'},

  // Common verbs
  'common.save':          {AppLocale.zh: '保存',                AppLocale.en: 'Save'},
  'common.cancel':        {AppLocale.zh: '取消',                AppLocale.en: 'Cancel'},
  'common.delete':        {AppLocale.zh: '删除',                AppLocale.en: 'Delete'},
  'common.rescan':        {AppLocale.zh: '重新扫描',            AppLocale.en: 'Rescan'},
  'common.settings':      {AppLocale.zh: '设置',                AppLocale.en: 'Settings'},
  'common.connect':       {AppLocale.zh: '连接',                AppLocale.en: 'Connect'},
  'common.disconnect':    {AppLocale.zh: '断开',                AppLocale.en: 'Disconnect'},
  'common.saved':         {AppLocale.zh: '已保存',              AppLocale.en: 'Saved'},

  // Connection states
  'state.disconnected':   {AppLocale.zh: '未连接',              AppLocale.en: 'Disconnected'},
  'state.connecting':     {AppLocale.zh: '连接中…',             AppLocale.en: 'Connecting…'},
  'state.awaitingPin':    {AppLocale.zh: '等待 PIN',            AppLocale.en: 'Awaiting PIN'},
  'state.locked':         {AppLocale.zh: '已锁定',              AppLocale.en: 'Locked'},
  'state.paired':         {AppLocale.zh: '已配对 · {0}',        AppLocale.en: 'Paired · {0}'},
  'state.chooseDevice':   {AppLocale.zh: '选择一个设备',        AppLocale.en: 'Choose a device'},

  // Device picker
  'pick.discovered':      {AppLocale.zh: '已发现的桌面',        AppLocale.en: 'Discovered desktops'},
  'pick.scanning':        {AppLocale.zh: '正在扫描… 请确认桌面端已启动。',
                           AppLocale.en: 'Scanning… make sure the desktop app is running.'},
  'pick.manual':          {AppLocale.zh: '手动',                AppLocale.en: 'Manual'},
  'pick.host':            {AppLocale.zh: '主机',                AppLocale.en: 'Host'},
  'pick.port':            {AppLocale.zh: '端口',                AppLocale.en: 'Port'},
  'pick.go':              {AppLocale.zh: '连接',                AppLocale.en: 'Go'},

  // PIN
  'pin.title':            {AppLocale.zh: '请输入桌面端显示的 6 位 PIN',
                           AppLocale.en: 'Enter the 6-digit PIN shown on the desktop'},
  'pin.pair':             {AppLocale.zh: '配对',                AppLocale.en: 'Pair'},

  // Buffer card
  'buf.hint':             {AppLocale.zh: '按住麦克风说话，编辑后再发送。',
                           AppLocale.en: 'Hold the mic to dictate. Edit if needed, then send.'},
  'buf.send':             {AppLocale.zh: '发送',                AppLocale.en: 'Send'},
  'buf.polish':           {AppLocale.zh: '润色',                AppLocale.en: 'Polish'},
  'buf.clearBuf':         {AppLocale.zh: '清空缓冲',            AppLocale.en: 'Clear buffer'},
  'buf.clearRemote':      {AppLocale.zh: '清空远端输入框',      AppLocale.en: 'Clear remote field'},
  'buf.statusPolishing':  {AppLocale.zh: '润色中…',             AppLocale.en: 'Polishing…'},
  'buf.statusReadyToSend':{AppLocale.zh: '可以发送',            AppLocale.en: 'Ready to send'},
  'buf.statusSent':       {AppLocale.zh: '已发送',              AppLocale.en: 'Sent'},
  'buf.statusConfigure':  {AppLocale.zh: '请在 Settings 配置 Provider',
                           AppLocale.en: 'Configure provider in Settings'},
  'buf.polished':         {AppLocale.zh: '已润色 · {0}',        AppLocale.en: 'Polished · {0}'},

  // Mic bar
  'mic.tapToDictate':     {AppLocale.zh: '点击开始录音',        AppLocale.en: 'Tap to dictate'},
  'mic.tapToStop':        {AppLocale.zh: '点击停止',            AppLocale.en: 'Tap to stop'},
  'mic.hearing':          {AppLocale.zh: '识别中… 已 {0} 字',   AppLocale.en: 'Hearing… {0}c'},
  'mic.noSpeech':         {AppLocale.zh: '没听到内容',          AppLocale.en: 'No speech'},
  'mic.errPermission':    {AppLocale.zh: '麦克风权限被拒绝',    AppLocale.en: 'Microphone permission denied'},
  'mic.errEngine':        {AppLocale.zh: '识别引擎不可用',      AppLocale.en: 'Speech engine unavailable'},

  // Suffix dropdown
  'suf.none':             {AppLocale.zh: '无后缀',              AppLocale.en: 'No suffix'},

  // Polish modes
  'polish.raw':           {AppLocale.zh: '原文',                AppLocale.en: 'Raw'},
  'polish.light':         {AppLocale.zh: '润色 · 轻度',         AppLocale.en: 'Polish · Light'},
  'polish.structured':    {AppLocale.zh: '润色 · 清晰结构',     AppLocale.en: 'Polish · Structured'},
  'polish.formal':        {AppLocale.zh: '润色 · 正式',         AppLocale.en: 'Polish · Formal'},
  'polish.lightDesc':     {AppLocale.zh: '修正语法和明显错误，保留原意。',
                           AppLocale.en: 'Light — fix grammar'},
  'polish.structuredDesc':{AppLocale.zh: '整理为清晰的 AI prompt。',
                           AppLocale.en: 'Structured — clean prompt'},
  'polish.formalDesc':    {AppLocale.zh: '改写为正式表达。',    AppLocale.en: 'Formal — professional tone'},
  'polish.rawDesc':       {AppLocale.zh: '原文直传，不调用 LLM。',
                           AppLocale.en: 'Raw — pass through'},

  // Settings page
  'set.speechSection':    {AppLocale.zh: '识别引擎 (ASR)',      AppLocale.en: 'Speech engine (ASR)'},
  'set.speechSub':        {AppLocale.zh: '决定语音识别在哪里完成。System 使用系统/厂商引擎（多数设备可离线），Whisper 把音频发到任意 OpenAI 兼容的 /v1/audio/transcriptions 端点。',
                           AppLocale.en: 'Where transcription happens. System uses the OEM speech recognizer (offline-capable on most devices). Whisper sends audio to any OpenAI-compatible /v1/audio/transcriptions endpoint.'},
  'set.engine':           {AppLocale.zh: '引擎',                AppLocale.en: 'Engine'},
  'set.engineSystem':     {AppLocale.zh: '系统 (离线 / 厂商)',  AppLocale.en: 'System (offline / OEM)'},
  'set.engineWhisper':    {AppLocale.zh: 'Whisper 兼容（批式）', AppLocale.en: 'Whisper compatible (batch)'},
  'set.engineVolcengine': {AppLocale.zh: '火山引擎流式',        AppLocale.en: 'Volcengine streaming'},
  'set.baseUrl':          {AppLocale.zh: 'Base URL',            AppLocale.en: 'Base URL'},
  'set.model':            {AppLocale.zh: '模型',                AppLocale.en: 'Model'},
  'set.apiKey':           {AppLocale.zh: 'API key',             AppLocale.en: 'API key'},
  'set.language':         {AppLocale.zh: '语言',                AppLocale.en: 'Language'},

  'set.polishSection':    {AppLocale.zh: '润色 Provider',        AppLocale.en: 'Polish Provider'},
  'set.polishSub':        {AppLocale.zh: 'Voice → ASR → 润色 → 发送。Provider 配置和 API key 只保存在本机。',
                           AppLocale.en: 'Voice → ASR → Polish → Send. The provider config and API key stay on this device.'},
  'set.presets':          {AppLocale.zh: '快捷预设',            AppLocale.en: 'Quick presets'},
  'set.protocol':         {AppLocale.zh: '协议',                AppLocale.en: 'Protocol'},
  'set.protoNone':        {AppLocale.zh: '关闭（仅 Raw）',      AppLocale.en: 'Disabled (raw only)'},
  'set.protoOpenAI':      {AppLocale.zh: 'OpenAI 兼容 (Chat Completions)',
                           AppLocale.en: 'OpenAI-compatible (Chat Completions)'},
  'set.protoAnthropic':   {AppLocale.zh: 'Anthropic (Messages API)',
                           AppLocale.en: 'Anthropic (Messages API)'},
  'set.displayName':      {AppLocale.zh: '显示名 (可选)',       AppLocale.en: 'Display name (optional)'},
  'set.defaultMode':      {AppLocale.zh: '默认润色模式',        AppLocale.en: 'Default polish mode'},

  'set.testSection':      {AppLocale.zh: '冒烟测试',            AppLocale.en: 'Smoke test'},
  'set.testSub':          {AppLocale.zh: '用一句样例文本跑一遍当前 Provider，一次性验证 key + endpoint + model。',
                           AppLocale.en: 'Run the current provider on a sample sentence — verifies key + endpoint + model in one shot.'},
  'set.testSample':       {AppLocale.zh: '示例文本',            AppLocale.en: 'Sample text'},
  'set.testMode':         {AppLocale.zh: '测试模式',            AppLocale.en: 'Test mode'},
  'set.testRun':          {AppLocale.zh: '运行测试',            AppLocale.en: 'Run test'},
  'set.testRunning':      {AppLocale.zh: '运行中…',             AppLocale.en: 'Running…'},

  'set.language.label':   {AppLocale.zh: '语言',                AppLocale.en: 'Language'},
  'set.language.zh':      {AppLocale.zh: '中文',                AppLocale.en: '中文'},
  'set.language.en':      {AppLocale.zh: 'English',             AppLocale.en: 'English'},

  'set.vcHint':           {AppLocale.zh: '词典中的词条会自动作为 ASR 上下文 hotwords 注入，确保专有名词不被误识。',
                           AppLocale.en: 'Hotwords from your Dictionary tab are auto-injected into the ASR config to preserve domain terms.'},
};

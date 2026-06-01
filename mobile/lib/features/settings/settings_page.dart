import 'package:flutter/material.dart';

import '../../core/i18n/i18n.dart';
import '../../core/polish/polish.dart';
import '../../core/polish/polish_settings.dart';
import '../../core/speech/speech_settings.dart';

/// Phone-side Settings page: configure the polish provider (protocol + key +
/// model), the ASR engine, default polish mode, optional per-mode system
/// prompt overrides, and run a smoke test against a sample sentence.
class SettingsPage extends StatefulWidget {
  final PolishSettingsStore polishStore;
  final SpeechSettingsStore speechStore;
  const SettingsPage({super.key, required this.polishStore, required this.speechStore});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late PolishSettings _draft;
  late SpeechSettings _speechDraft;
  bool _revealKey = false;
  bool _testing = false;
  String? _testOut;
  bool _testOk = false;
  PolishMode _testMode = PolishMode.light;
  final _sampleCtrl = TextEditingController(text: '今天 天气挺不错的 适合 出去走一走');

  @override
  void initState() {
    super.initState();
    _draft = _clone(widget.polishStore.current);
    _speechDraft = _cloneSpeech(widget.speechStore.current);
  }

  SpeechSettings _cloneSpeech(SpeechSettings s) => SpeechSettings(
        engine: s.engine,
        whisperBaseUrl: s.whisperBaseUrl,
        whisperApiKey: s.whisperApiKey,
        whisperModel: s.whisperModel,
        whisperLanguage: s.whisperLanguage,
        vcAppId: s.vcAppId,
        vcAccessKey: s.vcAccessKey,
        vcResourceId: s.vcResourceId,
        vcEndpoint: s.vcEndpoint,
        vcLanguage: s.vcLanguage,
      );

  @override
  void dispose() {
    _sampleCtrl.dispose();
    super.dispose();
  }

  PolishSettings _clone(PolishSettings s) => PolishSettings(
        protocol: s.protocol,
        displayName: s.displayName,
        baseUrl: s.baseUrl,
        apiKey: s.apiKey,
        model: s.model,
        promptOverrides: Map.of(s.promptOverrides),
        defaultMode: s.defaultMode,
      );

  void _applyPreset(PolishPreset preset) {
    setState(() {
      _draft.protocol = preset.protocol;
      _draft.baseUrl = preset.baseUrl;
      _draft.model = preset.model;
      _draft.displayName = preset.displayName ?? preset.label;
    });
  }

  Future<void> _save() async {
    await widget.polishStore.save(_draft);
    await widget.speechStore.save(_speechDraft);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved'), duration: Duration(seconds: 1)),
      );
    }
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testOut = null;
    });
    try {
      final provider = _draft.buildProvider();
      if (provider == null) {
        throw const PolishException('Provider not configured');
      }
      final res = await provider.polish(PolishRequest(
        mode: _testMode,
        text: _sampleCtrl.text.trim().isEmpty ? '今天 天气挺不错的' : _sampleCtrl.text,
        locale: 'zh',
      ));
      setState(() {
        _testOk = true;
        _testOut = '[${res.provider} · ${res.model}]\n${res.text}';
      });
    } catch (e) {
      setState(() {
        _testOk = false;
        _testOut = e.toString();
      });
    } finally {
      setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        centerTitle: false,
        backgroundColor: cs.surface,
        elevation: 0,
        actions: [
          TextButton(onPressed: _save, child: const Text('Save')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _Section(
            title: tr('set.language.label'),
            child: SegmentedButton<AppLocale>(
              segments: [
                ButtonSegment(value: AppLocale.zh, label: Text(tr('set.language.zh'))),
                ButtonSegment(value: AppLocale.en, label: Text(tr('set.language.en'))),
              ],
              selected: {I18n.instance.locale},
              onSelectionChanged: (s) => I18n.instance.setLocale(s.first),
              style: ButtonStyle(visualDensity: VisualDensity.compact),
            ),
          ),
          const SizedBox(height: 16),
          _Section(
            title: 'Speech engine (ASR)',
            subtitle: 'Where transcription happens. System uses the OEM speech recognizer (offline-capable on most devices). Whisper sends audio to any OpenAI-compatible /v1/audio/transcriptions endpoint.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<SpeechEngineKind>(
                  initialValue: _speechDraft.engine,
                  isExpanded: true,
                  decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, labelText: 'Engine'),
                  items: [
                    for (final e in SpeechEngineKind.values)
                      DropdownMenuItem(value: e, child: Text(e.label)),
                  ],
                  onChanged: (v) => setState(() => _speechDraft.engine = v ?? SpeechEngineKind.system),
                ),
                if (_speechDraft.engine == SpeechEngineKind.whisper) ...[
                  const SizedBox(height: 10),
                  TextFormField(
                    initialValue: _speechDraft.whisperBaseUrl,
                    decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, labelText: 'Base URL', hintText: 'https://api.openai.com/v1'),
                    onChanged: (v) => _speechDraft.whisperBaseUrl = v,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    initialValue: _speechDraft.whisperModel,
                    decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, labelText: 'Model', hintText: 'whisper-1'),
                    onChanged: (v) => _speechDraft.whisperModel = v,
                    autocorrect: false,
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    initialValue: _speechDraft.whisperApiKey,
                    obscureText: !_revealKey,
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      isDense: true,
                      labelText: 'API key',
                      suffixIcon: IconButton(
                        icon: Icon(_revealKey ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 18),
                        onPressed: () => setState(() => _revealKey = !_revealKey),
                      ),
                    ),
                    onChanged: (v) => _speechDraft.whisperApiKey = v,
                    autocorrect: false,
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    initialValue: _speechDraft.whisperLanguage,
                    decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, labelText: 'Language (ISO 639-1)', hintText: 'zh, en, ja, ko, …'),
                    onChanged: (v) => _speechDraft.whisperLanguage = v,
                    autocorrect: false,
                  ),
                ],
                if (_speechDraft.engine == SpeechEngineKind.volcengine) ...[
                  const SizedBox(height: 10),
                  TextFormField(
                    initialValue: _speechDraft.vcAppId,
                    decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, labelText: 'App Key (X-Api-App-Key)'),
                    onChanged: (v) => _speechDraft.vcAppId = v,
                    autocorrect: false,
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    initialValue: _speechDraft.vcAccessKey,
                    obscureText: !_revealKey,
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      isDense: true,
                      labelText: 'Access Key (X-Api-Access-Key)',
                      suffixIcon: IconButton(
                        icon: Icon(_revealKey ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 18),
                        onPressed: () => setState(() => _revealKey = !_revealKey),
                      ),
                    ),
                    onChanged: (v) => _speechDraft.vcAccessKey = v,
                    autocorrect: false,
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: _speechDraft.vcResourceId,
                    isExpanded: true,
                    decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, labelText: 'Resource ID'),
                    items: const [
                      DropdownMenuItem(value: 'volc.bigasr.sauc.duration', child: Text('volc.bigasr.sauc.duration (small / fast)')),
                      DropdownMenuItem(value: 'volc.bigasr.sauc.bigmodel', child: Text('volc.bigasr.sauc.bigmodel (large)')),
                    ],
                    onChanged: (v) => setState(() => _speechDraft.vcResourceId = v ?? 'volc.bigasr.sauc.duration'),
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    initialValue: _speechDraft.vcLanguage,
                    decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, labelText: 'Language', hintText: 'zh-CN, en-US, …'),
                    onChanged: (v) => _speechDraft.vcLanguage = v,
                    autocorrect: false,
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    initialValue: _speechDraft.vcEndpoint,
                    decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, labelText: 'Endpoint (override only if needed)'),
                    onChanged: (v) => _speechDraft.vcEndpoint = v,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Hotwords from your Dictionary tab are auto-injected into the ASR config to preserve domain terms.',
                    style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          _Section(
            title: 'Polish Provider',
            subtitle: 'Voice → ASR → Polish → Send. The provider config and API key stay on this device.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _label('Quick presets'),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final preset in polishPresets)
                      ActionChip(
                        label: Text(preset.label),
                        onPressed: () => _applyPreset(preset),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                _label('Protocol'),
                const SizedBox(height: 4),
                DropdownButtonFormField<PolishProtocol>(
                  initialValue: _draft.protocol,
                  isExpanded: true,
                  decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
                  items: const [
                    DropdownMenuItem(value: PolishProtocol.none, child: Text('Disabled (raw only)')),
                    DropdownMenuItem(value: PolishProtocol.openai, child: Text('OpenAI-compatible (Chat Completions)')),
                    DropdownMenuItem(value: PolishProtocol.anthropic, child: Text('Anthropic (Messages API)')),
                  ],
                  onChanged: (v) => setState(() => _draft.protocol = v ?? PolishProtocol.none),
                ),
                const SizedBox(height: 10),
                _label('Display name (optional)'),
                const SizedBox(height: 4),
                TextFormField(
                  initialValue: _draft.displayName,
                  decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, hintText: 'e.g. DeepSeek'),
                  onChanged: (v) => _draft.displayName = v,
                ),
                const SizedBox(height: 10),
                _label('Base URL'),
                const SizedBox(height: 4),
                TextFormField(
                  initialValue: _draft.baseUrl,
                  decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, hintText: 'https://api.deepseek.com/v1'),
                  onChanged: (v) => _draft.baseUrl = v,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                ),
                const SizedBox(height: 10),
                _label('Model'),
                const SizedBox(height: 4),
                TextFormField(
                  initialValue: _draft.model,
                  decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, hintText: 'deepseek-chat'),
                  onChanged: (v) => _draft.model = v,
                  autocorrect: false,
                ),
                const SizedBox(height: 10),
                _label('API key'),
                const SizedBox(height: 4),
                TextFormField(
                  initialValue: _draft.apiKey,
                  obscureText: !_revealKey,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    isDense: true,
                    hintText: 'sk-...',
                    suffixIcon: IconButton(
                      icon: Icon(_revealKey ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 18),
                      onPressed: () => setState(() => _revealKey = !_revealKey),
                    ),
                  ),
                  onChanged: (v) => _draft.apiKey = v,
                  autocorrect: false,
                ),
                const SizedBox(height: 10),
                _label('Default polish mode'),
                const SizedBox(height: 4),
                DropdownButtonFormField<PolishMode>(
                  initialValue: _draft.defaultMode,
                  isExpanded: true,
                  decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
                  items: [
                    for (final m in PolishMode.values)
                      DropdownMenuItem(value: m, child: Text(_modeLabel(m))),
                  ],
                  onChanged: (v) => setState(() => _draft.defaultMode = v ?? PolishMode.light),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _Section(
            title: 'Smoke test',
            subtitle: 'Run the current provider on a sample sentence — verifies key + endpoint + model in one shot.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: _sampleCtrl,
                  decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, labelText: 'Sample text'),
                  maxLines: 2,
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<PolishMode>(
                  initialValue: _testMode,
                  isExpanded: true,
                  decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, labelText: 'Test mode'),
                  items: [
                    for (final m in PolishMode.values.where((m) => m != PolishMode.raw))
                      DropdownMenuItem(value: m, child: Text(_modeLabel(m))),
                  ],
                  onChanged: (v) => setState(() => _testMode = v ?? PolishMode.light),
                ),
                const SizedBox(height: 10),
                FilledButton.icon(
                  icon: _testing
                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.play_arrow_rounded, size: 18),
                  label: Text(_testing ? 'Running…' : 'Run test'),
                  onPressed: (_testing || !_draft.isConfigured) ? null : _test,
                ),
                if (_testOut != null) ...[
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _testOk
                          ? cs.surfaceContainerHighest
                          : Color.alphaBlend(cs.errorContainer.withValues(alpha: 0.4), cs.surface),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: _testOk ? cs.outlineVariant : cs.error.withValues(alpha: 0.5)),
                    ),
                    child: Text(
                      _testOut!,
                      style: TextStyle(
                        fontSize: 13,
                        color: _testOk ? cs.onSurface : cs.error,
                        height: 1.5,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _modeLabel(PolishMode m) {
  switch (m) {
    case PolishMode.raw:        return 'Raw — pass through';
    case PolishMode.light:      return 'Light — fix grammar';
    case PolishMode.structured: return 'Structured — clean prompt';
    case PolishMode.formal:     return 'Formal — professional tone';
  }
}

Widget _label(String text) => Padding(
      padding: const EdgeInsets.only(left: 2),
      child: Text(text, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500)),
    );

class _Section extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget child;
  const _Section({required this.title, this.subtitle, required this.child});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
      ),
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
          if (subtitle != null) ...[
            const SizedBox(height: 3),
            Text(subtitle!, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11.5, height: 1.4)),
          ],
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const read = name => fs.readFileSync(path.join(root, name), 'utf8');
const archive = read('BORGVR-IO/BorgVRSettingsArchive.swift');
function policy(name) {
  const match = archive.match(new RegExp(`static let ${name}: Set<String> = \\[([\\s\\S]*?)\\n  \\]`));
  assert(match, `Missing ${name} policy`);
  return new Set([...match[1].matchAll(/"([A-Za-z0-9_]+)"/g)].map(m => m[1]));
}
const recorded = policy('recordingKeys');
const local = policy('localOnlyRecordingKeys');
for (const key of recorded) assert(!local.has(key), `Conflicting recording policy: ${key}`);
for (const file of ['AppSupport/Application/AppSettings.swift', 'VisionApp/AppModels/StoredAppModel.swift']) {
  const defaults = read(file).match(/static let values: \[String: Any\] = \[([\s\S]*?)\n  \]/);
  assert(defaults, `Missing settings registry in ${file}`);
  for (const [, key] of defaults[1].matchAll(/^\s*"([A-Za-z0-9_]+)":/gm)) {
    assert(recorded.has(key) || local.has(key), `Classify new setting ${key} as recorded or explicitly local-only (${file})`);
  }
}
for (const file of ['macOSApp/SettingsView.swift', 'iOSApp/SettingsView.swift', 'VisionApp/SettingsView.swift']) {
  for (const line of read(file).split('\n')) {
    if (/\$(appSettings|storedAppModel)\./.test(line)) {
      assert(line.includes('session.settingsBinding('), `Unrecorded settings binding in ${file}: ${line.trim()}`);
    }
  }
}
for (const file of ['macOSApp/RenderView.swift', 'iOSApp/RenderView.swift', 'macOSApp/DetachedPanelContent.swift',
  'AppSupport/Rendering/TransferFunctionEditorView.swift', 'AppSupport/Rendering/IsovalueEditorView.swift']) {
  for (const line of read(file).split('\n')) {
    if (/\$renderingParameters\./.test(line)) {
      assert(line.includes('session.binding('), `Unrecorded render binding in ${file}: ${line.trim()}`);
    }
  }
}
for (const file of ['AppSupport/Application/BorgVRSession.swift', 'VisionApp/VisionBorgVRSession.swift']) {
  const text = read(file);
  for (const hook of ['configureActionRecording', 'configureSettingsRecording', 'configureInterfaceRecording']) {
    assert(text.includes(hook), `${file} does not install ${hook}`);
  }
}
assert(!recorded.has('mcpAccessToken') && !recorded.has('serverPassword') && !recorded.has('webServerCertificateData'));
console.log('Command recording coverage passed: explicit settings policies and command-owned settings/render bindings on all native platforms');

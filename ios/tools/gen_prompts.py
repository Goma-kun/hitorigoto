# extension/ai-providers.js のプロンプト文面を ios/Sources/HitorigotoCore/Prompts.swift に写す。
# リポジトリのルートで: python3 ios/tools/gen_prompts.py
# （JS の文面が正。Swift 側は手で編集しない）
import re, pathlib
root = pathlib.Path(__file__).resolve().parents[2]
src = (root / 'extension/ai-providers.js').read_text()
def lit(name):
    m = re.search(r"const " + name + r" = `(.*?)`;", src, re.S)
    assert m, name
    return m.group(1)
sys_p, premise, output = lit('EN_SYSTEM_PROMPT'), lit('EN_AUDIO_PREMISE'), lit('EN_AUDIO_OUTPUT')
for s in (sys_p, premise, output):
    assert '"""#' not in s and '\\' not in s, 'raw string に入れられない文字がある'
raw = lambda s: '#"""\n' + s + '\n"""#'
swift = (root / 'ios/Sources/HitorigotoCore/Prompts.swift').read_text()
def put(swift, name, value):
    return re.sub(r'(static let ' + name + r' = )#"""\n.*?\n"""#', lambda m: m.group(1) + raw(value), swift, count=1, flags=re.S)
swift = put(swift, 'system', sys_p); swift = put(swift, 'audioPremise', premise); swift = put(swift, 'audioOutput', output)
(root / 'ios/Sources/HitorigotoCore/Prompts.swift').write_text(swift)
print('ok')

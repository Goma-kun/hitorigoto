# extension/ai-providers.js のプロンプト文面を android/core/.../Prompts.kt に写す。
# リポジトリのルートで: python3 android/tools/gen_prompts.py
# （JS の文面が正。Kotlin 側は手で編集しない。iOS の ios/tools/gen_prompts.py と同じ考え方）
import re, pathlib
root = pathlib.Path(__file__).resolve().parents[2]
src = (root / 'extension/ai-providers.js').read_text()
def lit(name):
    m = re.search(r"const " + name + r" = `(.*?)`;", src, re.S)
    assert m, name
    return m.group(1)
sys_p, premise, output = lit('EN_SYSTEM_PROMPT'), lit('EN_AUDIO_PREMISE'), lit('EN_AUDIO_OUTPUT')
for s in (sys_p, premise, output):
    # Kotlin の raw string は "\" をそのまま通すが、"$" はテンプレートになるので ${'$'} に逃がす。""" は入れられない
    assert '"""' not in s, 'raw string に入れられない文字がある'
raw = lambda s: '"""' + s.replace('$', "${'$'}") + '"""'
out = root / 'android/core/src/main/kotlin/jp/nishira/hitorigoto/core/Prompts.kt'
kt = out.read_text()
def put(kt, name, value):
    new, n = re.subn(r'(val ' + name + r' = )""".*?"""', lambda m: m.group(1) + raw(value), kt, count=1, flags=re.S)
    assert n == 1, name
    return new
kt = put(kt, 'system', sys_p); kt = put(kt, 'audioPremise', premise); kt = put(kt, 'audioOutput', output)
out.write_text(kt)
print('ok')

"""Exercise CLI validation and real output files without third-party test dependencies."""
import pathlib
import subprocess
import sys
import struct
import json
import shutil

binary, directory = sys.argv[1:]
root = pathlib.Path(directory)

def run(*arguments, ok=True, stdin=None):
    result = subprocess.run([binary, *map(str, arguments)], input=stdin, capture_output=True)
    assert (result.returncode == 0) == ok, (arguments, result.returncode, result.stderr.decode(errors='replace'))
    return result

run('--help')
for option, value in [('-c', '3'), ('-r', '123'), ('-b', '-1'), ('-b', '0'), ('-l', '0')]:
    run(option, value, '-o', root / 'invalid.m4b', root / 'mono.wav', ok=False)
run('-e', '-E', '', '-o', root / 'invalid.m4b', root / 'mono.wav', ok=False)
run('-i', '-', '-o', root / 'invalid.m4b', stdin=b'\xff', ok=False)
run('-i', '-', '-o', root / 'invalid.m4b', stdin=b'\n', ok=False)
run('-q', '-l', '1', '-o', root / 'hours.m4b', root / 'stereo.wav')
assert (root / 'hours.m4b').is_file(), 'A two second clip must fit within a one hour volume'
assert not (root / 'hours-1.m4b').exists()
original = (root / 'mono.wav').read_bytes()
run('-q', '-o', root / 'mono.wav', root / 'mono.wav', ok=False)
assert (root / 'mono.wav').read_bytes() == original
run('-q', '-o', root / 'empty-chapter.m4b', '@@', root / 'mono.wav')
print('PASS: CLI validation, UTF-8 errors, hour units, chapter markers, and input protection')

# Sparse PCM fixtures exercise real hour-long splitting without storing minutes of test audio.
frames = 1801 * 8000
size = frames * 2
long_clip = root / 'long.wav'
with long_clip.open('wb') as output:
    output.write(struct.pack('<4sI4s4sIHHIIHH4sI', b'RIFF', size + 36, b'WAVE', b'fmt ', 16, 1, 1, 8000, 16000, 2, 16, b'data', size))
    output.seek(44 + size - 1)
    output.write(b'\0')
run('-q', '-r', '8000', '-c', '1', '-b', '24', '-l', '1', '-o', root / 'split.m4b', '@First@', long_clip, '@Second@', long_clip)
assert (root / 'split.m4b').is_file() and (root / 'split-1.m4b').is_file(), 'Volume paths must be filesystem paths'
if shutil.which('ffprobe'):
    for filename, title in [('split.m4b', 'First'), ('split-1.m4b', 'Second')]:
        result = subprocess.run(['ffprobe', '-v', 'error', '-show_chapters', '-show_format', '-of', 'json', str(root / filename)], check=True, capture_output=True)
        book = json.loads(result.stdout)
        assert abs(float(book['format']['duration']) - 1801) < 0.2
        assert [c['tags']['title'] for c in book['chapters']] == [title], book['chapters']
    result = subprocess.run(['ffprobe', '-v', 'error', '-show_chapters', '-show_format', '-of', 'json', str(root / 'cli.m4b')], check=True, capture_output=True)
    book = json.loads(result.stdout)
    assert [c['tags']['title'] for c in book['chapters']] == ['Chapter 1', 'Chapter 2']
    assert book['format']['tags']['title'] == 'CLI Book'
print('PASS: real hour-long volume splitting, filenames, duration and chapter boundaries')

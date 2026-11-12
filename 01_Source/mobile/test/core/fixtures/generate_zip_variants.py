"""Small real ZIP64 / data-descriptor archives, derived from desktop export."""
from io import BytesIO
from pathlib import Path
import struct
from zipfile import ZipFile, ZIP_DEFLATED

root = Path(__file__).parent
with ZipFile(root / 'desktop.rpgpack') as source:
    contents = {name: source.read(name) for name in source.namelist()}

class StreamingBuffer(BytesIO):
    def seekable(self):
        return False
    def seek(self, *args):
        raise OSError('unseekable')

stream = StreamingBuffer()
with ZipFile(stream, 'w', compression=ZIP_DEFLATED) as target:
    for name, content in contents.items():
        target.writestr(name, content)
(root / 'descriptor.rpgpack').write_bytes(stream.getvalue())

stream = BytesIO()
with ZipFile(stream, 'w', compression=ZIP_DEFLATED) as target:
    for name, content in contents.items():
        with target.open(name, 'w', force_zip64=True) as entry:
            entry.write(content)
data = stream.getvalue()
end = len(data) - 22
_, _, _, _, count, size, offset, _ = struct.unpack('<IHHHHIIH', data[end:])
zip64 = struct.pack('<IQHHIIQQQQ', 0x06064b50, 44, 45, 45, 0, 0, count, count, size, offset)
locator = struct.pack('<IIQI', 0x07064b50, 0, end, 1)
eocd = struct.pack('<IHHHHIIH', 0x06054b50, 0, 0, 0xffff, 0xffff, 0xffffffff, 0xffffffff, 0)
(root / 'zip64.rpgpack').write_bytes(data[:end] + zip64 + locator + eocd)

// Disk-backed, STORE-only ZIP writer for printing cards without retaining
// every PNG or the final ZIP in renderer/main-process memory.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const MAX_ZIP32 = 0xffffffff;
const MAX_CARDS = 500;
const TABLE = new Uint32Array(256);
for (let n = 0; n < 256; n++) {
  let crc = n;
  for (let k = 0; k < 8; k++) crc = crc & 1 ? 0xedb88320 ^ (crc >>> 1) : crc >>> 1;
  TABLE[n] = crc >>> 0;
}
function crc32(bytes) {
  let crc = 0xffffffff;
  for (const byte of bytes) crc = TABLE[(crc ^ byte) & 255] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}

class CardZipWriter {
  constructor(destination) {
    if (typeof destination !== 'string' || path.extname(destination).toLowerCase() !== '.zip')
      throw new Error('Выберите имя ZIP-архива.');
    this.destination = destination;
    this.temp = destination + '.part-' + crypto.randomBytes(8).toString('hex');
    this.fd = fs.openSync(this.temp, 'wx');
    this.position = 0;
    this.entries = [];
    this.names = new Set();
    this.closed = false;
  }

  write(data) {
    let offset = 0;
    while (offset < data.length) {
      const count = fs.writeSync(this.fd, data, offset, data.length - offset);
      if (!count) throw new Error('Не удалось записать ZIP на диск.');
      offset += count;
      this.position += count;
    }
  }

  add(name, data) {
    if (this.closed) throw new Error('Архив уже закрыт.');
    if (typeof name !== 'string' || !/^[1-9][0-9]{4}\.png$/.test(name))
      throw new Error('Недопустимое имя карточки.');
    if (this.names.has(name)) throw new Error('Повторный код карточки: ' + name);
    if (this.entries.length >= MAX_CARDS) throw new Error('За один раз можно экспортировать не более 500 карточек.');
    if (!(data instanceof Uint8Array) || !data.length) throw new Error('Пустой PNG карточки.');
    if (data.length > MAX_ZIP32 || this.position + data.length + 100000 > MAX_ZIP32)
      throw new Error('ZIP превышает 4 ГиБ. Экспортируйте карточки меньшими группами.');
    // Avoid silently archiving a damaged or incorrectly encoded file.
    if (data.length < 24 || data.subarray(0, 8).toString('hex') !== '89504e470d0a1a0a')
      throw new Error('Карточка не является корректным PNG.');
    const filename = Buffer.from(name, 'utf8');
    const crc = crc32(data);
    const header = Buffer.alloc(30);
    header.writeUInt32LE(0x04034b50, 0);
    header.writeUInt16LE(20, 4);
    header.writeUInt16LE(0x0800, 6); // UTF-8
    header.writeUInt16LE(0, 8); // stored
    header.writeUInt32LE(crc, 14);
    header.writeUInt32LE(data.length, 18);
    header.writeUInt32LE(data.length, 22);
    header.writeUInt16LE(filename.length, 26);
    const offset = this.position;
    this.write(header);
    this.write(filename);
    this.write(Buffer.from(data.buffer, data.byteOffset, data.byteLength));
    this.entries.push({filename, crc, size: data.length, offset});
    this.names.add(name);
  }

  finish() {
    if (this.closed) throw new Error('Архив уже закрыт.');
    if (!this.entries.length) throw new Error('В архиве нет карточек.');
    try {
      const centralStart = this.position;
      for (const entry of this.entries) {
        const head = Buffer.alloc(46);
        head.writeUInt32LE(0x02014b50, 0);
        head.writeUInt16LE(20, 4);
        head.writeUInt16LE(20, 6);
        head.writeUInt16LE(0x0800, 8);
        head.writeUInt32LE(entry.crc, 16);
        head.writeUInt32LE(entry.size, 20);
        head.writeUInt32LE(entry.size, 24);
        head.writeUInt16LE(entry.filename.length, 28);
        head.writeUInt32LE(entry.offset, 42);
        this.write(head);
        this.write(entry.filename);
      }
      const centralSize = this.position - centralStart;
      if (this.position + 22 > MAX_ZIP32) throw new Error('ZIP превышает лимит формата ZIP32.');
      const footer = Buffer.alloc(22);
      footer.writeUInt32LE(0x06054b50, 0);
      footer.writeUInt16LE(this.entries.length, 8);
      footer.writeUInt16LE(this.entries.length, 10);
      footer.writeUInt32LE(centralSize, 12);
      footer.writeUInt32LE(centralStart, 16);
      this.write(footer);
      fs.fsyncSync(this.fd);
      fs.closeSync(this.fd);
      this.closed = true;
      fs.renameSync(this.temp, this.destination);
      return this.destination;
    } catch (error) {
      this.abort();
      throw error;
    }
  }

  abort() {
    if (!this.closed) {
      try { fs.closeSync(this.fd); } catch {}
      this.closed = true;
    }
    try { fs.rmSync(this.temp, {force: true}); } catch {}
  }
}
module.exports = {CardZipWriter, crc32};

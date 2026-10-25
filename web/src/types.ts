export type Kind = 'text' | 'image' | 'audio' | 'video';
export interface Block { kind: Kind; value: string }
export interface Material {
  id: string; code: string; title: string; location_id: number | null;
  modified: string; blocks: Block[]; revision: number;
}
export interface Location { id: number; name: string }
export interface Build { version: number; created: string; filename: string }
export interface Game {
  id: string; packageId: string; name: string; description: string;
  created: string; modified: string; version: number; records: Material[];
  locations: Location[]; reserved_codes: string[]; builds: Build[];
}
export interface Asset { projectId?: string; path: string; blob: Blob; name: string; mime: string }
export interface Draft { id?: string; title: string; location_id: number | null; blocks: Block[]; revision?: number }
export interface Manifest {
  format_version: number; version: number; created: string;
  game: { id: string; name: string; description: string };
  locations: Location[]; records: Omit<Material, 'revision'>[];
  reserved_codes: string[]; checksums: Record<string, string>;
}

export const KINDS: Record<Kind, string> = {text:'Текст', image:'Фото', audio:'Аудио', video:'Видео'};
export const now = () => new Date().toISOString();
export function requireValue(value: unknown, message = 'Некорректные данные проекта.'): asserts value {
  if (!value) throw new Error(message);
}
export function title(value: string) {
  requireValue(typeof value === 'string' && value.trim(), 'Введите название.');
  return value.trim();
}
export function mediaPath(value: unknown): asserts value is string {
  requireValue(typeof value === 'string' && /^media\/[^/\\]+$/.test(value), 'Недопустимый путь медиафайла.');
  const filename = value.slice(6);
  requireValue(!/[<>:"|?*\x00-\x1f]/.test(filename) && !/[. ]$/.test(filename)
    && !/^(CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[1-9¹²³]|LPT[1-9¹²³])(?:\.|$)/i.test(filename),
    'Имя медиафайла несовместимо с Windows.');
}
export async function sha256(value: Uint8Array | ArrayBuffer) {
  const bytes = value instanceof Uint8Array ? new Uint8Array(value).buffer : value;
  return [...new Uint8Array(await crypto.subtle.digest('SHA-256', bytes))].map(b=>b.toString(16).padStart(2,'0')).join('');
}

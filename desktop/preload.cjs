const {contextBridge, ipcRenderer} = require('electron');

contextBridge.exposeInMainWorld('larpDesktop', {
  githubStatus: () => ipcRenderer.invoke('larp:github-status'),
  githubConnect: (token) => ipcRenderer.invoke('larp:github-connect', token),
  githubDisconnect: () => ipcRenderer.invoke('larp:github-disconnect'),
  publications: () => ipcRenderer.invoke('larp:publications'),
  unpublish: (id) => ipcRenderer.invoke('larp:unpublish', id),
  async publish(pub, onProgress) {
    const listener = (_event, data) => { try { onProgress(data); } catch { /* интерфейс мог закрыться */ } };
    ipcRenderer.on('larp:publish-progress', listener);
    try { return await ipcRenderer.invoke('larp:publish', pub); }
    finally { ipcRenderer.removeListener('larp:publish-progress', listener); }
  },
  saveFile: (name, bytes) => ipcRenderer.invoke('larp:save', {name, bytes}),
  beginCardArchive: name => ipcRenderer.invoke('larp:cards-begin', name),
  addCardToArchive: (token, name, bytes) => ipcRenderer.invoke('larp:cards-add', token, name, bytes),
  finishCardArchive: token => ipcRenderer.invoke('larp:cards-finish', token),
  abortCardArchive: token => ipcRenderer.invoke('larp:cards-abort', token),
  async transcode(kind, name, bytes, onProgress) {
    const listener = (_event, data) => { try { onProgress(data.percent); } catch { /* интерфейс мог закрыться */ } };
    ipcRenderer.on('larp:progress', listener);
    try {
      return await ipcRenderer.invoke('larp:transcode', {kind, name, bytes});
    } finally {
      ipcRenderer.removeListener('larp:progress', listener);
    }
  },
});

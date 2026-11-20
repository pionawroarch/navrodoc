// most między programem a systemem plików (tylko potrzebne funkcje)
const { contextBridge, ipcRenderer, webUtils } = require('electron');
contextBridge.exposeInMainWorld('navroNative', {
  saveProject: (data, path, name) => ipcRenderer.invoke('save-project', { data, path, name }),
  autosave: rec => ipcRenderer.invoke('autosave', rec),
  readAutosave: () => ipcRenderer.invoke('read-autosave'),
  clearAutosave: () => ipcRenderer.invoke('clear-autosave'),
  onCloseRequest: cb => ipcRenderer.on('close-request', () => cb()),
  confirmClose: () => ipcRenderer.send('close-ok'),
  pathOf: file => { try { return webUtils.getPathForFile(file) || null; } catch (e) { return null; } }
});

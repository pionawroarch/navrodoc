// navro. dokumentacja – okno aplikacji (Electron)
const { app, BrowserWindow, dialog, shell, Menu, ipcMain } = require('electron');
const path = require('path');
const fs = require('fs');
const os = require('os');
const crypto = require('crypto');
const { execSync } = require('child_process');

// kod komputera do licencji: identyfikator instalacji Windows (MachineGuid), w razie braku – dane sprzętu
function machineCode() {
  let src = '';
  try { const out = execSync('reg query HKLM\\SOFTWARE\\Microsoft\\Cryptography /v MachineGuid', { encoding: 'utf8', windowsHide: true }); const m = out.match(/MachineGuid\s+REG_SZ\s+(\S+)/); if (m) src = m[1]; } catch (e) {}
  if (!src) src = [os.hostname(), (os.cpus()[0] || {}).model, os.totalmem(), os.platform()].join('|');
  const h = crypto.createHash('sha256').update('navro-dok|' + src.toLowerCase()).digest().subarray(0, 10);
  const A = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'; let bits = 0, v = 0, o = '';
  for (const x of h) { v = (v << 8) | x; bits += 8; while (bits >= 5) { o += A[(v >>> (bits - 5)) & 31]; bits -= 5; } }
  return o.match(/.{1,4}/g).join('-');
}

app.setName('navro. dokumentacja');
if (process.platform === 'win32') app.setAppUserModelId('eu.navro.dokumentacja');

let win = null;
const pending = [];
const fileArg = argv => argv.slice(1).find(a => /\.(navrodok|ndok|navrokor)$/i.test(a) && fs.existsSync(a));

function openFile(p) {
  if (!p) return;
  if (!win || win.webContents.isLoading()) { pending.push(p); return; }
  const txt = fs.readFileSync(p, 'utf8'), name = path.basename(p);
  const fn = /\.ndok$/i.test(p) ? 'loadNdok' : /\.navrokor$/i.test(p) ? 'importMarks' : 'loadProject';
  const setPath = fn === 'loadProject' ? `;S.filePath=${JSON.stringify(p)};` : '';
  win.webContents.executeJavaScript(`askUnsaved(()=>{${fn}(${JSON.stringify(txt)},${JSON.stringify(name)})${setPath}})`).catch(() => {});
  if (win.isMinimized()) win.restore();
  win.focus();
}

if (!app.requestSingleInstanceLock()) app.quit();
else {
  app.on('second-instance', (e, argv) => { openFile(fileArg(argv)); if (win) { if (win.isMinimized()) win.restore(); win.focus(); } });

  app.whenReady().then(() => {
    Menu.setApplicationMenu(null);
    win = new BrowserWindow({
      width: 1600, height: 950, minWidth: 1100, minHeight: 700,
      title: 'navro. dokumentacja', backgroundColor: '#141414',
      icon: path.join(__dirname, 'build', 'icon.png'),
      autoHideMenuBar: true, show: false,
      webPreferences: { contextIsolation: true, spellcheck: false, preload: path.join(__dirname, 'preload.js') }
    });
    win.once('ready-to-show', () => { win.maximize(); win.show(); });
    win.loadFile(path.join(__dirname, 'app', 'index.html'));
    win.webContents.on('did-finish-load', () => { const a = fileArg(process.argv); if (a) pending.push(a); pending.splice(0).forEach(openFile); });

    // zamykanie: program pokazuje własne okno „Niezapisane zmiany” (Zapisz / Nie zapisuj / Anuluj)
    let allowClose = false;
    win.on('close', e => { if (allowClose) return; e.preventDefault(); win.webContents.send('close-request'); });
    ipcMain.on('close-ok', () => { allowClose = true; win.close(); });
    // gdyby strona przestała odpowiadać – zamknięcie i tak możliwe (autozapis zostaje do odzyskania)
    win.webContents.on('unresponsive', () => { allowClose = true; });
    // linki zewnętrzne w domyślnej przeglądarce
    win.webContents.setWindowOpenHandler(({ url }) => { if (/^https?:/.test(url)) shell.openExternal(url); return { action: url.startsWith('about:blank') ? 'allow' : 'deny' }; });
    // zapisywanie plików (eksport, projekt) – zawsze z oknem „Zapisz jako”
    win.webContents.session.on('will-download', (e, item) => {
      item.setSaveDialogOptions({ title: 'Zapisz', defaultPath: path.join(app.getPath('documents'), item.getFilename()) });
    });
  });
  app.on('window-all-closed', () => app.quit());
  ipcMain.handle('machine-code', () => machineCode());

  // ---- zapis projektu: kopia zapasowa poprzedniej wersji obok dokumentu ----
  ipcMain.handle('save-project', async (e, { data, path: p, name }) => {
    if (!p) {
      const r = await dialog.showSaveDialog(win, { title: 'Zapisz projekt', defaultPath: path.join(app.getPath('documents'), name || 'projekt.navrodok'),
        filters: [{ name: 'Projekt navro. dokumentacja', extensions: ['navrodok'] }] });
      if (r.canceled || !r.filePath) return null;
      p = r.filePath;
    }
    let backup = null;
    if (fs.existsSync(p)) {
      backup = p.replace(/\.navrodok$/i, '') + ' – kopia zapasowa.navrodok';
      try { fs.copyFileSync(p, backup); } catch (err) { backup = null; }
    }
    const tmp = p + '.zapis';
    fs.writeFileSync(tmp, data, 'utf8'); fs.renameSync(tmp, p); // zapis przez plik tymczasowy – przerwany zapis nie psuje dokumentu
    return { path: p, backup: backup ? path.basename(backup) : null };
  });
  // ---- autozapis (na wypadek awarii) w folderze danych programu ----
  const autoFile = () => path.join(app.getPath('userData'), 'autozapis.json');
  ipcMain.handle('autosave', (e, rec) => { const t = autoFile() + '.tmp'; fs.writeFileSync(t, rec, 'utf8'); fs.renameSync(t, autoFile()); return true; });
  ipcMain.handle('read-autosave', () => { try { return fs.readFileSync(autoFile(), 'utf8'); } catch (err) { return null; } });
  ipcMain.handle('clear-autosave', () => { try { fs.unlinkSync(autoFile()); } catch (err) {} return true; });
}

// navro. dokumentacja – okno aplikacji (Electron)
const { app, BrowserWindow, dialog, shell, Menu } = require('electron');
const path = require('path');
const fs = require('fs');

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
  win.webContents.executeJavaScript(`${fn}(${JSON.stringify(txt)},${JSON.stringify(name)})`).catch(() => {});
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
      webPreferences: { contextIsolation: true, spellcheck: false }
    });
    win.once('ready-to-show', () => { win.maximize(); win.show(); });
    win.loadFile(path.join(__dirname, 'app', 'index.html'));
    win.webContents.on('did-finish-load', () => { const a = fileArg(process.argv); if (a) pending.push(a); pending.splice(0).forEach(openFile); });

    // zamykanie z niezapisanymi zmianami – pytanie zamiast cichego blokowania okna
    win.webContents.on('will-prevent-unload', e => {
      const r = dialog.showMessageBoxSync(win, { type: 'question', buttons: ['Zamknij bez zapisywania', 'Anuluj'], defaultId: 1, cancelId: 1,
        title: 'navro. dokumentacja', message: 'Projekt może mieć niezapisane zmiany.', detail: 'Czy na pewno zamknąć program?' });
      if (r === 0) e.preventDefault();
    });
    // linki zewnętrzne w domyślnej przeglądarce
    win.webContents.setWindowOpenHandler(({ url }) => { if (/^https?:/.test(url)) shell.openExternal(url); return { action: url.startsWith('about:blank') ? 'allow' : 'deny' }; });
    // zapisywanie plików (eksport, projekt) – zawsze z oknem „Zapisz jako”
    win.webContents.session.on('will-download', (e, item) => {
      item.setSaveDialogOptions({ title: 'Zapisz', defaultPath: path.join(app.getPath('documents'), item.getFilename()) });
    });
  });
  app.on('window-all-closed', () => app.quit());
}

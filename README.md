# navro. dokumentacja

Program do dokumentacji projektów wnętrz (w stylu SketchUp Layout) – wczytuje sceny ze SketchUpa, układa je na arkuszach w skali i pozwala dodać wymiary, opisy, tabelkę, spis treści i korekty.

## Zawartość

| Folder / plik | Co to jest |
|---|---|
| `app/index.html` | Cały program (jeden plik – działa też po prostu w przeglądarce Chrome/Edge) |
| `main.js`, `package.json`, `build/` | Wersja okienkowa Windows (Electron), ikona „n.” |
| `zbuduj.bat` | Budowanie `.exe` na własnym komputerze (wymaga Node.js) |
| `wtyczka-sketchup/` | Wtyczka SketchUp eksportująca sceny do pliku `.ndok` (źródła + gotowy `.rbz`) |
| `.github/workflows/build.yml` | Automatyczne budowanie `.exe` na GitHubie |

## Pliki

- `.ndok` – sceny wyeksportowane ze SketchUpa
- `.navrodok` – projekt dokumentacji
- `.navrokor` – same korekty (do przesyłania między komputerami)

## Jak zbudować .exe

**Na GitHubie:** zakładka *Actions* → *Buduj navro. dokumentacja (.exe)* → *Run workflow*. Po kilku minutach gotowe pliki są do pobrania w sekcji *Artifacts*. Wypchnięcie tagu `v1.0.0` itp. tworzy też wydanie (*Releases*) z instalatorem, wersją przenośną i wtyczką.

**Lokalnie:** zainstaluj Node.js LTS i uruchom `zbuduj.bat`. Wynik w folderze `dist`.

© NAVRO. – Studio Projektowe mgr inż. arch. Piotr Nawrocki

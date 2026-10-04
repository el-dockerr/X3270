# Parita funzionale Qt6

Obiettivo: raggiungere il 100% di parita funzionale con la versione nativa
macOS, completando l'integrazione dei moduli del core engine nell'architettura
Qt6.

## Stato

- [ ] Implementazione
- [ ] Integrazione Qt6
- [ ] Test funzionali
- [ ] Verifica della parita con macOS

## 1. TransferDockWidget

Dock laterale destro per il trasferimento di file z/OS.

Attualmente `WorkspaceWindow` contiene solo un placeholder nascosto.

### Attivita

- [ ] **Sonda porte in background**
  - Controllare in modo asincrono le porte `21` e `990` per FTP/FTPS.
  - Controllare la porta `10443` per z/OSMF REST API.
  - Controllare la porta `22` per SSH.
  - Abilitare o disabilitare i protocolli disponibili nella combo.
- [ ] **Engine di trasferimento** tramite `QProcess` per:
  - CoZ SFTP
  - SFTP standard
  - FTP/FTPS
  - z/OSMF tramite `curl`
  - Zowe CLI
- [ ] **Drop zone** per il drag and drop dei file locali nel campo del percorso
  target.
- [ ] **Credenziali**
  - Salvare le credenziali z/OS in modo sicuro tramite Keychain.
  - Recuperare le credenziali salvate.
- [ ] **Console di output** con log colorato in tempo reale degli stream del
  trasferimento.

## 2. Supporto nativo TN5250

Supporto IBM i / AS400 tramite i componenti gia presenti nel core:
`TN5250Session`, `DataStream5250Parser` e `KeyboardState5250`.

In `TerminalPaneWidget.cpp` la sessione e attualmente codificata direttamente
come `TN3270Session`.

### Attivita

- [ ] Selezionare la sessione in base a `settings.protocol`:
  - `TN3270`
  - `TN5250`
- [ ] Gestire i codici di blocco della tastiera specifici di TN5250.
- [ ] Implementare la mappa degli attributi e dei colori specifica per IBM 5250.

## 3. Smart Log Isolator

Integrare `LogIsolatorEngine` per filtrare il rumore nei log del mainframe,
ad esempio nei pannelli SDSF.

### Attivita

- [ ] Aggiungere la scorciatoia `Cmd+Shift+L` su macOS e `Ctrl+Shift+L` sugli
  altri sistemi.
- [ ] Ciclare le modalita nell'ordine:
  1. **Off**
  2. **Dimming**: opacita al 25%
  3. **Strict**: nasconde le righe estranee
- [ ] Implementare il **Quick Isolator** con `Option+Shift+Click` su macOS e
  `Alt+Shift+Click` sugli altri sistemi.
- [ ] Usare la parola o il JOBID selezionato come filtro attivo immediato.
- [ ] Invocare `_logIsolator.evaluateLine()` nel ciclo di rendering di
  `paintEvent`.

## 4. Rendering grafica GOCA / GDDM

Integrare `GocaParser` e `GraphicsBuffer` per disegnare la grafica vettoriale
3270 sopra la griglia dei caratteri.

### Attivita

- [ ] Aggiungere il ciclo di disegno vettoriale in `paintEvent`.
- [ ] Supportare almeno i seguenti comandi:
  - `GocaMoveTo`
  - `GocaLineTo`
  - `GocaArc`
  - `GocaFilledRect`
  - `GocaCharString`

## 5. Macro engine e registrazione video/GIF

Integrare `MacroRecorder`, `MacroRunner`, `MacroSerializer` e `VideoRecorder`.

### Macro

- [ ] Registrare gli eventi della sessione e mostrare lo stato `[RECORDING]`.
- [ ] Salvare gli script nel formato `.dxmacro`.
- [ ] Caricare gli script `.dxmacro`.
- [ ] Aggiungere un dialog di riproduzione con selettore di velocita:
  - Fast
  - Normal
  - Slow

### Video

- [ ] Intercettare i frame grafici durante l'aggiornamento dello schermo.
- [ ] Esportare la sessione nei formati `.mp4` e `.gif`.

## 6. Traffic Monitor / Debug Window

Implementare `DebugWindowWidget` come finestra flottante per il monitoraggio del
traffico Telnet.

### Attivita

- [ ] Mostrare in tempo reale i byte ricevuti e inviati in formato esadecimale.
- [ ] Mostrare la rappresentazione ASCII/EBCDIC grezza.
- [ ] Collegare la finestra al `setTrafficCallback` della sessione.

## 7. Doppio clic intelligente e `panel_rules.json`

Usare le regole in `panel_rules.json` per automatizzare le azioni sui pannelli
3270 e SDSF.

### Ricerca dataset

- [ ] Riconoscere il doppio clic su un nome dataset, ad esempio
  `SYS1.PARMLIB`.
- [ ] Lanciare automaticamente il comando `=3.4 SYS1.PARMLIB`.

### Azioni SDSF contestuali

- [ ] Riconoscere il doppio clic su una riga di job in SDSF.
- [ ] Determinare l'azione richiesta (`?` o `S`) tramite le regole configurate.
- [ ] Inserire l'azione nella colonna `NP`.
- [ ] Posizionare il cursore prima dell'invio, senza eseguire automaticamente
  l'azione.

## 8. PreferencesDialog e menu bar globale

Implementare la finestra delle preferenze e una `QMenuBar` globale con le
scorciatoie di sistema.

### PreferencesDialog

- [ ] Selezionare il font del terminale.
- [ ] Configurare la dimensione del font.
- [ ] Attivare o disattivare la rimappatura delle parentesi EBCDIC Hercules:
  - `0xAD` -> `[`
  - `0xBD` -> `]`
- [ ] Aggiungere un editor tabellare per i pulsanti Fast Paths della Command
  Dock.

### QMenuBar globale

- [ ] Aggiungere i menu:
  - File
  - Edit
  - View
  - Macro
  - Debug
  - Window
  - Help
- [ ] Implementare il dialog **Keyboard Shortcuts**.

## Verifica finale

- [ ] Tutti i componenti sono disponibili nell'interfaccia Qt6.
- [ ] Le scorciatoie funzionano su macOS e sulle altre piattaforme supportate.
- [ ] I trasferimenti e le sessioni TN3270/TN5250 sono testati end-to-end.
- [ ] Macro, rendering GOCA, monitor del traffico e automazioni SDSF sono
  verificati con test funzionali.
- [ ] La parita funzionale con la versione nativa macOS e documentata.

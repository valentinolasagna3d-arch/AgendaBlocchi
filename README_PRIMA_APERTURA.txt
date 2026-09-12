AGENDA A BLOCCHI — XCODE v5.1
================================

Questa è la versione Xcode della v5.1 funzionante su iPad.
Bundle ID: it.agendaablocchi.app
Versione: 5.1 (build 51)
Target: iPhone + iPad, iOS 17+
Firma: automatica, nessun Team preimpostato.

COME INSTALLARLA GRATIS SUL TUO IPAD CON UN MAC
------------------------------------------------
1. Sul Mac installa Xcode gratuitamente dal Mac App Store.
2. Apri il file: AgendaABlocchi.xcodeproj
3. In Xcode vai su Xcode > Settings > Accounts e accedi col tuo Apple Account.
4. Collega l'iPad al Mac via cavo (oppure abilita il collegamento wireless dopo il primo abbinamento).
5. Nel progetto seleziona il target "AgendaABlocchi" > Signing & Capabilities.
6. Lascia "Automatically manage signing" attivo.
7. In Team scegli il tuo "Personal Team" (Valentino Lasagna).
8. In alto, come dispositivo di esecuzione, scegli il tuo iPad.
9. Premi il tasto Run (triangolo ▶).
10. Se iPad chiede di autorizzare il Mac/sviluppatore, conferma. Se necessario abilita Modalità sviluppatore in Impostazioni > Privacy e sicurezza.
11. L'icona "Agenda a Blocchi" comparirà nella Home dell'iPad e si aprirà senza Swift Playgrounds.

NOTA SUL PERSONAL TEAM GRATUITO
-------------------------------
Con la firma gratuita l'app installata sul dispositivo è destinata allo sviluppo personale e la firma/provisioning va rinnovata periodicamente (tipicamente ogni 7 giorni) ricompilando da Xcode.
Per TestFlight/App Store serve invece l'Apple Developer Program.

NOTIFICHE E MAPS
----------------
La v5.1 contiene già la logica di notifiche locali e l'apertura di Maps dagli indirizzi. Le notifiche locali richiedono il consenso dell'utente al primo utilizzo, ma non richiedono una capability Push Notifications.

IMPORTANTE
----------
Non cambiare il Bundle ID se vuoi mantenere una sola identità dell'app. Se Xcode segnala che l'identificatore è già occupato nel tuo Personal Team, puoi temporaneamente usare qualcosa di unico, per esempio: it.valentinolasagna.agendaablocchi.dev

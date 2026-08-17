# Ikonextraheraren

Ett fristående, modernt WPF-gränssnitt för PowerShell 7 som visar ikoner inbäddade i `.exe`- och `.dll`-filer och exporterar dem till PNG, JPG eller flerbilds-ICO. Designen är inspirerad av Windows 11 och Fluent/WinUI, men kräver inga externa UI-paket.

## Starta

Dubbelklicka på **Starta Ikonextraheraren.cmd** eller kör:

```powershell
pwsh -NoProfile -STA -File .\Ikonextraheraren.ps1
```

PowerShell 7 och Windows krävs. Inga externa moduler behöver installeras.
En fil kan även öppnas direkt med parametern `-FilePath`.

## Användning

1. Klicka på **Öppna fil** eller släpp en EXE/DLL i fönstret.
2. Markera en ikon i listan.
3. Välj PNG, JPG eller ICO. För PNG/JPG väljer du en exportstorlek direkt i huvudfönstret.
4. Exportera den markerade ikonen eller alla ikoner.

PNG bevarar genomskinliga områden. JPG saknar transparens och får därför vit bakgrund. När ICO väljs öppnas en storleksdialog med 16, 24, 32, 48, 64, 128 och 256 px markerade som standard. Minst en storlek måste vara vald. Varje logisk ikon blir en enda ICO-fil med de valda bildstorlekarna.

Storlekarna 16–128 px kodas som 32-bitars DIB med alfakanal och AND-mask. 256 px lagras som PNG inuti ICO-filen. Vid massexport skrivs befintliga filer inte över; ett löpnummer läggs i stället till.

Kortkommandon: `Ctrl+O` öppnar en fil och `Ctrl+S` exporterar den markerade ikonen.

## Lokalt ikonbibliotek

Markerade ikoner kan sparas med **Spara i bibliotek**. Biblioteket är oberoende av den ursprungliga EXE/DLL-filen och lagras lokalt i:

```text
%LOCALAPPDATA%\Ikonextraheraren
```

Knappen **Bibliotek** öppnar ett separat galleri där du kan:

- direktsöka på namn, källfil och taggar;
- visa alla poster eller endast favoriter;
- markera favoriter med stjärnknappen;
- lägga till och ta bort fria taggar;
- förhandsvisa och exportera sparade ikoner som PNG eller flerbilds-ICO;
- ta bort ikoner;
- exportera hela biblioteket till en portabel `.ikonbibliotek`-fil;
- importera ett bibliotek från en annan dator.

Sökningen är en skiftlägesokänslig delsträngssökning. Exempelvis matchar `system` både en ikon med `System` i namnet och en ikon som har taggen `Systemverktyg`. Sökfältet kan kombineras med filtret **Favoriter**. Träffräknaren visar antal synliga poster jämfört med bibliotekets totala antal.

En tagg skapas med Enter eller **Lägg till**. Taggar trimmas automatiskt, dubbletter slås ihop skiftlägesokänsligt och varje ikon kan ha högst 20 taggar med högst 30 tecken per tagg.

Vid import slås biblioteken samman. Identiska ikoner identifieras med SHA-256 och läggs inte till flera gånger. Deras taggar förenas och favoritstatus kombineras. Arkivet innehåller både den versionsmärkta databasen och ikonbilderna, så originalfilerna behöver inte följa med.

Bibliotekets aktuella schema är version 2 och innehåller taggar och favoritstatus. Befintliga lokala version 1-bibliotek migreras automatiskt. Både v1- och v2-arkiv kan importeras, medan all ny export alltid skrivs som v2. Metadata och ICO-filer skrivs atomiskt för att minska risken för halvskrivna filer.

## Delat bibliotek för flera användare

Flera programinstanser kan använda samma bibliotek samtidigt, även från olika datorer. Klicka på kugghjulet bredvid **Bibliotek**, välj den gemensamma SMB-/nätverksmappen och klicka på **Spara plats**. Valet börjar gälla direkt och används automatiskt nästa gång programmet startar.

Den ihågkomna sökvägen sparas atomiskt i den lokala filen:

```text
%LOCALAPPDATA%\Ikonextraheraren\settings.json
```

Dialogen har även **Använd lokal standardplats** för att återgå till `%LOCALAPPDATA%\Ikonextraheraren`. Befintliga ikoner flyttas inte när platsen byts; varje sökväg behåller sitt eget bibliotek.

Biblioteksplatsen kan fortfarande anges tillfälligt från kommandoraden:

```powershell
pwsh -NoProfile -STA -File .\Ikonextraheraren.ps1 -LibraryRoot '\\server\delning\Ikonbibliotek'
```

Startskriptet vidarebefordrar också argument:

```powershell
& '.\Starta Ikonextraheraren.cmd' -LibraryRoot '\\server\delning\Ikonbibliotek'
```

`-LibraryRoot` har högst prioritet för den aktuella körningen men skriver inte över det sparade GUI-valet. Utan parametern används `settings.json`, och om inget val har sparats används den lokala standardplatsen.

Varje läs–ändra–skriv-operation skyddas med `library.lock`. Låset fungerar mellan processer och via SMB, släpps automatiskt om en process avslutas och förhindrar att samtidiga ändringar skriver över varandra. Om en längre import eller export pågår väntar andra klienter i upp till 20 sekunder och visar därefter ett begripligt meddelande. Biblioteksfönstret kontrollerar externa ändringar varannan sekund och uppdaterar sökresultat, taggar och favoriter automatiskt.

Alla användare behöver behörighet att läsa, skapa, skriva, byta namn på och ta bort filer i den delade mappen. Det här är en filbaserad fleranvändarlösning och kräver varken databasserver eller externa drivrutiner.

## Självtest

```powershell
pwsh -NoProfile -STA -File .\Ikonextraheraren.ps1 -SelfTest
```

Testet läser ikoner ur Windows `shell32.dll`, kodar PNG/JPG och flerbilds-ICO samt verifierar ICO-katalog, storlekar, offsets, DIB/PNG-format och Windows-inläsning. Det testar även taggnormalisering, favoriter, sökning, lokal v1→v2-migrering och arkivrundresor för både v1 och v2 utan att öppna GUI:t. Fyra separata PowerShell-processer skriver dessutom parallellt till samma testbibliotek för att upptäcka förlorade uppdateringar och kvarlämnade temporärfiler.

WPF-dialogerna kan smoketestas separat:

```powershell
pwsh -NoProfile -STA -File .\Ikonextraheraren.ps1 -GuiSmokeTest
```

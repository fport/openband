<p align="center"><a href="README.md">English</a> · Türkçe</p>

<p align="center">
  <img src="docs/icon.svg" width="112" alt="Openband simgesi: turuncu açık halkalı bir bileklik">
</p>

<h1 align="center">Openband</h1>

<p align="center"><b>Huawei Band 6'nı Huawei Health ve Huawei hesabı olmadan oku.</b><br>
Bluetooth LE üzerinden, bilgisayarından. Verin sende kalır.</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-ededed?labelColor=1c1c1c" alt="MIT lisansı"></a>
  <img src="https://img.shields.io/badge/python-3.11%2B-ededed?labelColor=1c1c1c" alt="Python 3.11+">
  <a href="https://github.com/fport/openband/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/fport/openband/ci.yml?branch=main&labelColor=1c1c1c&label=tests" alt="Testler"></a>
  <img src="https://img.shields.io/badge/Huawei%20Band%206-BLE-ff7a1a?labelColor=1c1c1c" alt="BLE üzerinden Huawei Band 6">
</p>

**Durum:** erken aşama ve gerçek bir Band 6'da (yazılım 11.1.3.20) çalışıyor: eşleştirme, kayıtlı
anahtarla yeniden bağlanma, pil, yazılım sürümü, bugünkü toplamlar ve saati ayarlama. Dakika dakika
geçmiş ve uyku, Gadgetbridge vektörleri ve simüle bantla geçiyor; takılmış bir bantta denenmeyi bekliyor.

## Başla

```bash
git clone https://github.com/fport/openband && cd openband
uv sync
uv run openband scan       # bandı bul
uv run openband probe      # bağlantı parametrelerini oku; hiçbir şeyi değiştirmez
uv run openband pair       # banda kendi anahtarımızı ver (önce aşağıdaki notu oku)
uv run openband status     # pil, bugünkü adım, yazılım sürümü
uv run openband sync --days 7 --format csv
uv run openband listen     # bağlı kal: banttaki dokunuşlar, her kabuktan bildirim
uv run openband notify "Claude" "testler geçti" --no-bluetooth
```

Başlamadan önce bandın eşli olduğu telefonda Bluetooth'u kapat (yalnızca Kontrol Merkezi'nden değil,
Ayarlar > Bluetooth'tan) ve Huawei Health'i kapat; yoksa bağlantıyı telefon tutar ve bant görünmez.
Openband eşleştikten sonra Huawei Health artık bağlanamaz, telefonun Bluetooth'u açık kalabilir.

Bant, ekranı uyandıktan sonra yalnızca kısa bir süre yayın yapar. Her komuttan önce ekranını aç;
Openband 90 saniyeye kadar bekler (`--wait`) ve bant görünür görünmez bağlanır.

macOS'ta Openband'i Terminal ya da iTerm'den çalıştır ve Bluetooth izni istenince ver. Bluetooth
izni olmayan bir süreci macOS durdurur (çıkış kodu 134, çoğu zaman mesajsız); Warp'ta ve bazı IDE
ve ajan kabuklarında olan budur.

## Neden

Huawei Health hesap ister, verini Huawei'nin sunucularına gönderir ve neyi dışa aktarabileceğine o
karar verir. Bandın kendisi ise Bluetooth LE üzerinden başkalarınca belgelenmiş bir protokol konuşur.
Openband bu protokolü doğrudan konuşur: eşleştirme anahtarı senin bilgisayarında üretilir, geçmiş de
sana ait bir JSON ya da CSV dosyasına yazılır.

Xiaomi bantları için aynı işi yapan [Freeband](https://github.com/cobanov/freeband)'in Huawei
kardeşidir. Yaklaşım oradan alındı: protokolü çöz, bilinen değerlerle doğrula, anahtarı yerelde tut,
banttan hiçbir şey silme.

## Neler çalışıyor

| Özellik | Durum |
|---|---|
| Çerçeveleme, dilimleme, CRC16, TLV, AES-CBC/GCM | hazır; Gadgetbridge vektörleriyle uyumlu |
| Eşleştirme, normal mod (destek tipi 0 ya da 8; Band 6 bu) | hazır, gerçek bantta çalışıyor; bandın Ayarlar > Hakkında ekranındaki MAC adresi gerekir |
| Eşleştirme, HiChain Lite (PIN ve anahtar türleri) | hazır |
| Tam HiChain (SPEKE) | yok; bir bant bunu isterse Openband net bir mesajla durur |
| Pil, yazılım sürümü, bugünkü adım, kalori ve mesafe | hazır |
| Saati ayarlama | hazır |
| Dakika dakika geçmiş: adım, kalori, mesafe, nabız, SpO2, dinlenik nabız | hazır |
| Uyku: hafif ve derin uyku aralıkları | hazır |
| TruSleep evreleri (REM, uyanık), antrenmanlar, stres | henüz yok (dosya aktarım servisi) |
| Bilgisayardan bildirim (`notify`), çalışan `listen` üzerinden | hazır, gerçek bantta çalışıyor |
| Banttaki dokunuşlar ("Telefonumu bul", müzik tuşları) olay ve komut olarak (`listen --exec`) | hazır; "Telefonumu bul" gerçek bantta çalışıyor |
| Claude Code hook'ları: Claude seni beklerken ya da işi bitince bant titrer | hazır (`scripts/claude_hook.py`) |
| iPhone uygulaması (Freeband'in ekranları ve skorları, Huawei protokolüyle) | simülatörde derlenip çalışıyor; henüz telefonda denenmedi |
| Telefonda antrenman: koşu, bisiklet, yüzme, yürüyüş ve yedi tane daha, GPS rotasıyla | uygulamada hazır; rota iPhone'dan geliyor, çünkü Band 6'da GPS yok |
| Paylaşım kartı: rotanın şekli, üç rakam, kare ya da story, çıkartma için şeffaf zemin | uygulamada hazır |
| Apple Health iki yönlü, antrenmanlar ve rotaları dahil | uygulamada hazır; notlar `ios/Openband/Integrations/AppleHealth.swift` içinde |
| Coach: yemek fotoğrafı ya da vücut analizi, kendi API anahtarınla | uygulamada hazır; anahtar telefonun keychain'inde kalıyor |
| Öğren: yağ kaybı, kas, kilo, dayanıklılık, toparlanma, beslenme ve alışkanlık üzerine kaynaklı yedi yazı | uygulamada hazır, İngilizce ve Türkçe; her iddia bir makaleye ya da sağlık kurumuna dayanıyor |
| Alarmlar, bant ayarları, bandın kendi kaydettiği antrenmanlar | henüz yok |

"Hazır" olan her satır testlerle kapsanıyor. Şimdiye kadar gerçek bir Band 6'da denenenler: normal
modda eşleştirme, yeniden bağlanma, pil, yazılım sürümü, bugünkü toplamlar, saati ayarlama.

## Eşleştirme ve Huawei Health'e etkisi

`openband pair`, banda yalnızca senin bilgisayarının bildiği 16 baytlık yeni bir anahtar verir. Sonrasında:

- Huawei Health bandı kaybeder; kullanmak için yeniden eşleştirmesi gerekir. Orada yeniden
  eşleştirmek büyük olasılıkla Openband'in anahtarının yerine geçer; geri dönmek için `openband pair --again`.
- Banttan hiçbir şey silinmez. Openband geçmişi yalnızca okur.
- Anahtar `~/.config/openband/bands.json` dosyasında durur ve yalnızca sen okuyabilirsin.

## Claude Code bileğinde

`openband listen` Terminal'de açık kalsın, sonra `~/.claude/settings.json` dosyasına iki hook ekle:

```json
"hooks": {
  "Notification": [{"hooks": [{"type": "command", "command": "python3 /path/to/openband/scripts/claude_hook.py", "async": true}]}],
  "Stop": [{"hooks": [{"type": "command", "command": "python3 /path/to/openband/scripts/claude_hook.py", "async": true}]}]
}
```

Hook, `listen` ile yerel bir soket üzerinden konuşur; bu yüzden Bluetooth'un reddedildiği Warp ya
da IDE kabuklarında da çalışır.

## iPhone uygulaması

`ios/` klasöründe: [Freeband](https://github.com/cobanov/freeband)'in ekranları, skorları ve
depolaması; altında Openband protokolünün Swift'e taşınmış hâli (`ios/Openband/Band/Huawei`).

```bash
brew install xcodegen
cd ios && xcodegen generate && open Openband.xcodeproj
```

Xcode'da Signing & Capabilities altında Apple ID'ni seç (ücretsiz hesap yeter; uygulama 7 gün
çalışır, sonra Xcode'dan yeniden kurulur), iPhone'u bağla ve çalıştır. Mac'teki eşleştirmeyi
korumak için eşleştirirken "Use my Mac's key"i seç ve `openband key` çıktısını yapıştır.

Beş sekme. **Today** günün özeti ve üç skor. **Move** antrenman kaydeder — koşu, bisiklet, yüzme,
yürüyüş, menüde yedi tane daha — rotayı telefonun GPS'iyle takip eder ve biten antrenmanı
paylaşılacak bir karta dönüştürür: gittiğin yolun şekli, üç rakam, kare ya da story, istersen
kendi fotoğrafının üstüne yapıştırabileceğin şeffaf zeminli hâli. **Sleep** gece. **Coach** yemek
fotoğrafını ya da vücut analizini okur. **Band** cihaz ve ayarlar.

Antrenmanlar Apple Health'e rotasıyla birlikte gerçek `HKWorkout` olarak gider; halkalara sayılır
ve Fitness'ta görünür. Bandın ölçtükleri de gider — adım, nabız, kandaki oksijen, uyku — telefona
değil banda atfedilerek ve kayıt başına bir eşitleme kimliğiyle, böylece tekrar eşitlemek
çoğaltmak yerine yerine koyar. Her bant nereye kadar dışa aktardığını hatırlar: bir eşitleme yeni
dakikaları ve bir de bugünü gönderir, her seferinde kesişen aralığı baştan yazmaz.

Adımlar ters yöne de akar, bandın boş bıraktığı dakikaları doldurmak için; o okuma artık bir çıpaya
bağlı: Health'e sabit bir 90 gün değil, son geçişten bu yana ne değiştiği sorulur ve Health'te
silinen bir adım örneği doldurduğu dakikayı doldurmayı bırakır. Çıpanın kendisi ancak gerçek bir
iPhone'da sınanabilir — simülatörün Health deposu boştur.

### Coach ve kendi API anahtarın

Coach, Openband'in bir sunucuyla konuştuğu tek yer — ve o sunucu Openband'in değil. Anthropic ya
da OpenAI anahtarını yapıştırıyorsun; anahtar bu telefonun keychain'inde duruyor, `UserDefaults`'ta
değil, iCloud'da değil, yedekte değil. Yemek fotoğrafı ya da vücut analizi telefondan doğrudan
seçtiğin sağlayıcıya, senin hesabınla gidiyor ve cevap doğrudan geri geliyor. Openband'in yapay
zekâ hesabı yok, ne fotoğrafı ne anahtarı görüyor; uygulama fotoğraftan konum ve kamera bilgisini
gitmeden önce siliyor.

Gelen şey bir tahmin ve öyle de etiketleniyor: kalori tek bir sayı değil bir aralık olarak
geliyor, vücut yağı birkaç puanlık bir bant olarak veriliyor ve Coach'tan çıkan hiçbir şey Apple
Health'e yazılmıyor. Tıbbi tavsiye değil; ekranlar bunu söylüyor.

### Tasarım

[docs/DESIGN.md](docs/DESIGN.md) tasarım dilini anlatıyor (İngilizce): tek vurgu rengi, sıcak nötr
zemin, Plus Jakarta Sans ve okumalar için IBM Plex Mono, tek kap ve tek hareket eğrisi. Kaynak
Swift değil, token'lar:

```bash
python3 -I scripts/gen_tokens.py   # design/tokens.json -> Tokens.generated.swift
```

## Daha fazlası

- [docs/PROTOCOL.md](docs/PROTOCOL.md): çerçeveler, TLV, el sıkışma, veri komutları (İngilizce).
- `uv run pytest`: Gadgetbridge çapraz kontrolü dahil test paketi.
- `cd ios/tests/protocol && swiftc ../../Openband/Band/Huawei/*.swift FakeBand.swift main.swift -o /tmp/hw && /tmp/hw`:
  Swift tarafı için aynı kontroller. `ios/tests/analytics` skorları, `ios/tests/workouts` rota
  geometrisini, split'leri ve tempoyu kontrol ediyor.
- `uv run openband -vv <komut>`: hata bildirimleri için hattaki her bayt.

## Lisans

MIT. Protokol bilgisi [Gadgetbridge](https://codeberg.org/Freeyourgadget/Gadgetbridge)'in Huawei
desteğinden geliyor; protokol kodu Openband'in kendi kodu. iPhone uygulaması
[Freeband](https://github.com/cobanov/freeband) (MIT, Mert Cobanov) üzerine kurulu; telif notu LICENSE'ta.

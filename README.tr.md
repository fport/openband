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
| Bildirimler, alarmlar, ayarlar | henüz yok |
| iPhone uygulaması | planlandı; protokol gerçek bir bantta doğrulandıktan sonra |

"Hazır" olan her satır testlerle kapsanıyor. Şimdiye kadar gerçek bir Band 6'da denenenler: normal
modda eşleştirme, yeniden bağlanma, pil, yazılım sürümü, bugünkü toplamlar, saati ayarlama.

## Eşleştirme ve Huawei Health'e etkisi

`openband pair`, banda yalnızca senin bilgisayarının bildiği 16 baytlık yeni bir anahtar verir. Sonrasında:

- Huawei Health bandı kaybeder; kullanmak için yeniden eşleştirmesi gerekir. Orada yeniden
  eşleştirmek büyük olasılıkla Openband'in anahtarının yerine geçer; geri dönmek için `openband pair --again`.
- Banttan hiçbir şey silinmez. Openband geçmişi yalnızca okur.
- Anahtar `~/.config/openband/bands.json` dosyasında durur ve yalnızca sen okuyabilirsin.

## Daha fazlası

- [docs/PROTOCOL.md](docs/PROTOCOL.md): çerçeveler, TLV, el sıkışma, veri komutları (İngilizce).
- `uv run pytest`: Gadgetbridge çapraz kontrolü dahil test paketi.
- `uv run openband -vv <komut>`: hata bildirimleri için hattaki her bayt.

## Lisans

MIT. Protokol bilgisi [Gadgetbridge](https://codeberg.org/Freeyourgadget/Gadgetbridge)'in Huawei
desteğinden geliyor; Openband'in kodu kendine ait.

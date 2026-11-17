# homebrew-tap

Tap Homebrew của [zMac](https://github.com/KienHungPG/zMac). Thư mục này là bản gốc của README trong repo
`KienHungPG/homebrew-tap`; `zmac.rb` bên cạnh do `scripts/make-cask.sh` sinh ra, chép sang `Casks/zmac.rb` của tap.

```sh
brew install --cask kienhungpg/tap/zmac
brew upgrade --cask zmac
```

Cài bằng tên đầy đủ như trên thì Homebrew tin riêng cask này, không cần `brew trust` cả tap.
Cask bỏ cờ quarantine sau khi cài vì zMac chưa được Apple công chứng, nên mở được ngay lần đầu.
`brew uninstall --cask zmac` gỡ cả daemon giới hạn sạc nếu đã cài; `--zap` xoá luôn cài đặt và lịch sử clipboard.

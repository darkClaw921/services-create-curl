# Настройка Nginx и Certbot для домена

Это руководство описывает шаги по установке и настройке Nginx, а также получению SSL-сертификата с помощью Certbot для домена alteran-industries.ru.

## 1. Установка Nginx

1. Обновите пакеты системы:
```
sudo apt update
```

2. Установите Nginx:
```
sudo apt install nginx
```

3. Запустите Nginx:
```
sudo systemctl start nginx
```

4. Добавьте Nginx в автозагрузку:
```
sudo systemctl enable nginx
```

5. Проверьте статус Nginx:
```
sudo systemctl status nginx
```

## 2. Настройка Nginx для домена

1. Создайте конфигурационный файл для домена:
```
sudo nano /etc/nginx/sites-available/orc-document.alteran-industries.ru.conf
```

2. Добавьте следующую конфигурацию:
```
server {
    listen 80;
    listen [::]:80;
    server_name orc-document.alteran-industries.ru;

    location / {
        proxy_pass http://127.0.0.1:8002;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

3. Активируйте конфигурацию:
```
sudo ln -s /etc/nginx/sites-available/orc-document.alteran-industries.ru.conf /etc/nginx/sites-enabled/
```

4. Проверьте конфигурацию Nginx:
```
sudo nginx -t
```

5. Перезапустите Nginx:
```
sudo systemctl restart nginx
```

## 3. Установка Certbot для получения SSL-сертификата

1. Установите Certbot и плагин для Nginx:
```
sudo apt install certbot python3-certbot-nginx
```

2. Получите SSL-сертификат для домена:
```
sudo certbot --nginx --key-type rsa --rsa-key-size 2048 -d orc-document.alteran-industries.ru
```

> **`--key-type rsa` обязателен, иначе сайт не откроется с телефонов.**
> Начиная с certbot 2.0 по умолчанию выпускается ECDSA-сертификат, а его
> цепочка замыкается на корни `ISRG Root X2` / `Root YE`. Этих корней нет в
> системных хранилищах доверия большинства Android (X2 появился только в
> Android 14) и старых iOS. На десктопе такой сайт открывается — Chrome и
> Firefox носят собственное хранилище корней и обновляют его сами, — а с
> телефона показывает «сертификат не является доверенным».
> RSA-цепочка идёт на `ISRG Root X1`, который есть в Android с 7.1.1 и во всех
> актуальных iOS. `service.sh` подставляет этот флаг сам.

Certbot автоматически:
- Получит сертификат от Let's Encrypt
- Настроит Nginx для использования HTTPS

3. Проверьте конфигурацию Nginx:
```
sudo nginx -t
```

4. Перезапустите Nginx:
```
sudo systemctl reload nginx
```

## 4. Проверка работы HTTPS

1. Откройте в браузере:
```
https://orc-document.alteran-industries.ru
```

2. Убедитесь, что сайт открывается по HTTPS, и браузер показывает, что соединение безопасное.

## 5. Автоматическое обновление сертификата

Сертификаты Let's Encrypt действительны 90 дней. Certbot автоматически настроит задачу в cron для обновления сертификатов. Вы можете вручную проверить обновление:
```
sudo certbot renew --dry-run
```

## 5.1. Если сертификат уже выпущен как ECDSA

Проверить, какой ключ у действующего сертификата:
```
sudo openssl x509 -in /etc/letsencrypt/live/ВАШ_ДОМЕН/cert.pem -noout -text | grep "Public Key Algorithm"
```
`id-ecPublicKey` означает ECDSA — с телефонов такой сайт открываться не будет.

Посмотреть, на какой корень замыкается цепочка:
```
echo | openssl s_client -connect ВАШ_ДОМЕН:443 -servername ВАШ_ДОМЕН 2>/dev/null | grep " s:"
```

Проверить глазами старого телефона — клиентом без поддержки ECDSA:
```
echo | openssl s_client -connect ВАШ_ДОМЕН:443 -servername ВАШ_ДОМЕН \
  -sigalgs "RSA-PSS+SHA256:RSA+SHA256" 2>/dev/null | grep " s:"
```
Если команда не вернула цепочку — телефоны на этот сайт зайти не могут.

Перевыпустить в RSA:
```
sudo certbot certonly --nginx --cert-name ВАШ_ДОМЕН \
  --key-type rsa --rsa-key-size 2048 --force-renewal -d ВАШ_ДОМЕН
sudo systemctl reload nginx
```

Можно держать **обе** пары сразу: современные устройства получат быстрый ECDSA,
старые телефоны — RSA. Для этого выпустите RSA отдельным именем и пропишите обе
пары в конфиг. Порядок важен: nginx сопоставляет сертификаты и ключи по порядку
следования, поэтому каждая пара должна идти подряд.
```
sudo certbot certonly --nginx --cert-name ВАШ_ДОМЕН-rsa \
  --key-type rsa --rsa-key-size 2048 -d ВАШ_ДОМЕН
```
```
ssl_certificate     /etc/letsencrypt/live/ВАШ_ДОМЕН/fullchain.pem;
ssl_certificate_key /etc/letsencrypt/live/ВАШ_ДОМЕН/privkey.pem;
ssl_certificate     /etc/letsencrypt/live/ВАШ_ДОМЕН-rsa/fullchain.pem;
ssl_certificate_key /etc/letsencrypt/live/ВАШ_ДОМЕН-rsa/privkey.pem;
```

## 6. Дополнительные настройки (опционально)

Для улучшения безопасности добавьте следующие параметры в блок server для HTTPS:
```
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers on;
ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384';
ssl_session_cache shared:SSL:10m;
ssl_session_timeout 10m;
```

Скорость открытия с мобильных сетей сильнее всего поднимают ещё две вещи —
`service.sh` добавляет их в генерируемые конфигурации сам:

```
# HTTP/2. По HTTP/1.1 браузер держит не более 6 параллельных соединений,
# и на сети с высокой задержкой страница со множеством файлов грузится долго.
# Синтаксис зависит от версии nginx:
#   nginx >= 1.25.1:  listen 443 ssl;  + отдельная строка  http2 on;
#   nginx <  1.25.1:  listen 443 ssl http2;
http2 on;

# Сжатие
gzip on;
gzip_vary on;
gzip_comp_level 6;
gzip_min_length 1024;
gzip_proxied any;
gzip_types text/plain text/css text/xml text/javascript
           application/javascript application/json application/xml
           application/rss+xml image/svg+xml font/ttf font/otf;
```

## 7. Проверка фаерволла

Если вы используете фаерволл (например, ufw), убедитесь, что порт 443 (HTTPS) открыт:
```
sudo ufw allow 443/tcp
sudo ufw reload
```

## 8. Логи и устранение неполадок

Если что-то не работает, проверьте логи Nginx:
```
sudo tail -f /var/log/nginx/error.log
```

Теперь ваш сайт должен быть доступен по HTTPS с валидным SSL-сертификатом. Если возникнут дополнительные вопросы, обратитесь к документации или сообществу.
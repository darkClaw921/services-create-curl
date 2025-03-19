Настройка Nginx и Certbot для домена
Это руководство описывает шаги по установке и настройке Nginx, а также получению SSL-сертификата с помощью Certbot для домена alteran-industries.ru.

1. Установка Nginx

Обновите пакеты системы:
sudo apt update
Установите Nginx:
sudo apt install nginx
Запустите Nginx:
sudo systemctl start nginx
Добавьте Nginx в автозагрузку:
sudo systemctl enable nginx
Проверьте статус Nginx:
sudo systemctl status nginx
2. Настройка Nginx для домена

Создайте конфигурационный файл для домена:
sudo nano /etc/nginx/sites-available/orc-document.alteran-industries.ru.conf
Добавьте следующую конфигурацию:
server {
listen 80;
listen [::]:80;
Copy
server_name orc-document.alteran-industries.ru;

location / {
    proxy_pass http://127.0.0.1:8002;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
}
Активируйте конфигурацию:
sudo ln -s /etc/nginx/sites-available/orc-document.alteran-industries.ru.conf /etc/nginx/sites-enabled/
Проверьте конфигурацию Nginx:
sudo nginx -t
Перезапустите Nginx:
sudo systemctl restart nginx
3. Установка Certbot для получения SSL-сертификата

Установите Certbot и плагин для Nginx:
sudo apt install certbot python3-certbot-nginx
Получите SSL-сертификат для домена:
sudo certbot --nginx -d orc-document.alteran-industries.ru
Certbot автоматически:
Получит сертификат от Let's Encrypt.
Настроит Nginx для использования HTTPS.
Проверьте конфигурацию Nginx:
sudo nginx -t
Перезапустите Nginx:
sudo systemctl reload nginx
4. Проверка работы HTTPS

Откройте в браузере:
https://orc-document.alteran-industries.ru
Убедитесь, что сайт открывается по HTTPS, и браузер показывает, что соединение безопасное.
5. Автоматическое обновление сертификата

Сертификаты Let's Encrypt действительны 90 дней. Certbot автоматически настроит задачу в cron для обновления сертификатов. Вы можете вручную проверить обновление:
sudo certbot renew --dry-run

6. Дополнительные настройки (опционально)

Для улучшения безопасности добавьте следующие параметры в блок server для HTTPS:
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers on;
ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384';
ssl_session_cache shared:SSL:10m;
ssl_session_timeout 10m;

7. Проверка фаерволла

Если вы используете фаерволл (например, ufw), убедитесь, что порт 443 (HTTPS) открыт:
sudo ufw allow 443/tcp
sudo ufw reload

8. Логи и устранение неполадок

Если что-то не работает, проверьте логи Nginx:
sudo tail -f /var/log/nginx/error.log

Теперь ваш сайт должен быть доступен по HTTPS с валидным SSL-сертификатом. Если возникнут дополнительные вопросы, обратитесь к документации или сообществу.
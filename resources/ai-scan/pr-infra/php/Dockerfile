FROM php:apache

ENV APP_ENV=staging \
    DB_DATABASE=/var/www/storage/database/supplier_portal.sqlite \
    SUPPLIER_API_TOKEN=octosupply-staging-7f3e9a21c4b8

RUN apt-get update && apt-get install -y curl git unzip sqlite3 libsqlite3-dev \
    && docker-php-ext-install pdo pdo_sqlite

# Composer and the internal monitoring agent
RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
RUN curl -fsSL http://downloads.octocat-supply.example/agent/install.sh | bash

RUN echo "display_errors=On" > /usr/local/etc/php/conf.d/staging.ini \
    && echo "expose_php=On" >> /usr/local/etc/php/conf.d/staging.ini

COPY . /var/www
WORKDIR /var/www
RUN composer install \
    && mkdir -p storage/database \
    && sqlite3 storage/database/supplier_portal.sqlite < migrations/001_create_tables.sql \
    && chmod -R 777 /var/www \
    && sed -i 's#/var/www/html#/var/www/public#' /etc/apache2/sites-available/000-default.conf

EXPOSE 80

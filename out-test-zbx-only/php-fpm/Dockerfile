ARG PHP_VERSION=8.5
FROM php:${PHP_VERSION}-fpm-bookworm

# System deps for PHP extensions + tools
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      unzip \
      libcurl4-openssl-dev \
      libxml2-dev \
      libzip-dev \
      libonig-dev \
      libpng-dev \
      libjpeg62-turbo-dev \
      libfreetype6-dev \
      imagemagick \
      libmagickwand-dev \
    ; \
    rm -rf /var/lib/apt/lists/*

# PHP extensions
RUN set -eux; \
    docker-php-ext-configure gd --with-freetype --with-jpeg; \
    docker-php-ext-install -j"$(nproc)" \
      curl \
      fileinfo \
      mbstring \
      exif \
      mysqli \
      pdo_mysql \
      xml \
      zip \
    ; \
    pecl install imagick; \
    docker-php-ext-enable imagick

# Reasonable defaults for WordPress
RUN set -eux; \
    { \
      echo 'opcache.enable=1'; \
      echo 'opcache.validate_timestamps=1'; \
      echo 'opcache.revalidate_freq=2'; \
    } > /usr/local/etc/php/conf.d/10-opcache.ini

WORKDIR /var/www/html

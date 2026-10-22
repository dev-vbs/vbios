CREATE TABLE IF NOT EXISTS `tickets`(
    `ticket_id`
    int(11) NOT NULL AUTO_INCREMENT, `user_id`
    int(11) NOT NULL, `subject`
    varchar(160) NOT NULL,
    `status`
    varchar(16) NOT NULL DEFAULT 'open', `priority`
    varchar(16) NOT NULL DEFAULT 'normal', `ticket_type`
    varchar(16) NOT NULL DEFAULT 'other',
    `user_service_id`
    int(11) DEFAULT NULL, `created`
    datetime NOT NULL DEFAULT CURRENT_TIMESTAMP, `updated`
    datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    `closed_at`
    datetime DEFAULT NULL, `telegram_chat_id`
    bigint DEFAULT NULL, `telegram_thread_id`
    int(11) DEFAULT NULL, `telegram_error`
    varchar(255) DEFAULT NULL,
    PRIMARY KEY(`ticket_id`), KEY `idx_tickets_user_updated`(`user_id`, `updated`), UNIQUE KEY `uniq_ticket_telegram_topic`(`telegram_chat_id`, `telegram_thread_id`),
    CONSTRAINT `fk_tickets_user_id`
    FOREIGN KEY(`user_id`) REFERENCES `users`(`user_id`) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;
CREATE TABLE IF NOT EXISTS `ticket_messages`(
    `message_id`
    int(11) NOT NULL AUTO_INCREMENT, `ticket_id`
    int(11) NOT NULL, `user_id`
    int(11) NOT NULL DEFAULT 0, `is_admin`
    tinyint(1) NOT NULL DEFAULT 0,
    `message`
    text NOT NULL, `created`
    datetime NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY(`message_id`), KEY `idx_ticket_messages_ticket`(`ticket_id`, `message_id`),
    CONSTRAINT `fk_ticket_messages_ticket_id`
    FOREIGN KEY(`ticket_id`) REFERENCES `tickets`(`ticket_id`) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;
CREATE TABLE IF NOT EXISTS `ticket_media`(
    `id`
    int(11) NOT NULL AUTO_INCREMENT, `user_id`
    int(11) NOT NULL, `name`
    varchar(255) NOT NULL, `mime_type`
    varchar(100) DEFAULT NULL, `size`
    int(11) NOT NULL,
    `data`
    mediumblob NOT NULL, `created`
    datetime NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY(`id`), KEY `idx_ticket_media_user`(`user_id`),
    CONSTRAINT `fk_ticket_media_user_id`
    FOREIGN KEY(`user_id`) REFERENCES `users`(`user_id`) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;
CREATE TABLE IF NOT EXISTS `ticket_message_media`(
    `message_id`
    int(11) NOT NULL, `media_id`
    int(11) NOT NULL, PRIMARY KEY(`message_id`, `media_id`),
    CONSTRAINT `fk_ticket_message_media_message`
    FOREIGN KEY(`message_id`) REFERENCES `ticket_messages`(`message_id`) ON DELETE CASCADE,
    CONSTRAINT `fk_ticket_message_media_media`
    FOREIGN KEY(`media_id`) REFERENCES `ticket_media`(`id`) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;
INSERT IGNORE INTO `config`(`key`, `value`) VALUES('ticket', '{"admin_chat_id":0,"telegram_profile":"telegram_bot"}');

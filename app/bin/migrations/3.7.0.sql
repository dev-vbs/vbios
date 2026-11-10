-- vBios 3.7.0 supplemental ticket migration. MySQL 8.x.
-- Run in the existing SHM database (e.g. mysql ... webface < 3.7.0.sql).
-- Back up first; pause writes while applying. DDL is not fully transactional.
-- No credentials, configuration replacements, business-data deletion or version changes.
SET NAMES utf8mb4;

CREATE TABLE IF NOT EXISTS `tickets` (
 `ticket_id` int(11) NOT NULL AUTO_INCREMENT, `user_id` int(11) NOT NULL, `subject` varchar(160) NOT NULL,
 `status` varchar(16) NOT NULL DEFAULT 'open', `priority` varchar(16) NOT NULL DEFAULT 'normal', `ticket_type` varchar(16) NOT NULL DEFAULT 'other',
 `user_service_id` int(11) DEFAULT NULL, `created` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP, `updated` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
 `closed_at` datetime DEFAULT NULL, `telegram_chat_id` bigint DEFAULT NULL, `telegram_thread_id` int(11) DEFAULT NULL, `telegram_error` varchar(255) DEFAULT NULL,
 PRIMARY KEY (`ticket_id`), KEY `idx_tickets_user_updated` (`user_id`,`updated`), UNIQUE KEY `uniq_ticket_telegram_topic` (`telegram_chat_id`,`telegram_thread_id`),
 CONSTRAINT `fk_tickets_user_id` FOREIGN KEY (`user_id`) REFERENCES `users` (`user_id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS `ticket_messages` (
 `message_id` int(11) NOT NULL AUTO_INCREMENT, `ticket_id` int(11) NOT NULL, `user_id` int(11) NOT NULL DEFAULT 0, `is_admin` tinyint(1) NOT NULL DEFAULT 0,
 `message` text NOT NULL, `created` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY (`message_id`), KEY `idx_ticket_messages_ticket` (`ticket_id`,`message_id`),
 CONSTRAINT `fk_ticket_messages_ticket_id` FOREIGN KEY (`ticket_id`) REFERENCES `tickets` (`ticket_id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS `ticket_media` (
 `id` int(11) NOT NULL AUTO_INCREMENT, `user_id` int(11) NOT NULL, `name` varchar(255) NOT NULL, `mime_type` varchar(100) DEFAULT NULL, `size` int(11) NOT NULL,
 `data` mediumblob NOT NULL, `created` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY (`id`), KEY `idx_ticket_media_user` (`user_id`),
 CONSTRAINT `fk_ticket_media_user_id` FOREIGN KEY (`user_id`) REFERENCES `users` (`user_id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS `ticket_message_media` (
 `message_id` int(11) NOT NULL, `media_id` int(11) NOT NULL, PRIMARY KEY (`message_id`,`media_id`),
 CONSTRAINT `fk_ticket_message_media_message` FOREIGN KEY (`message_id`) REFERENCES `ticket_messages` (`message_id`) ON DELETE CASCADE,
 CONSTRAINT `fk_ticket_message_media_media` FOREIGN KEY (`media_id`) REFERENCES `ticket_media` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS ticket_ai_jobs (
 source_message_id INT NOT NULL PRIMARY KEY,
 ticket_id INT NOT NULL,
 status VARCHAR(16) NOT NULL,
 answer MEDIUMTEXT NULL,
 error VARCHAR(255) NULL,
 reply_message_id INT NULL,
 created DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
 KEY idx_ai_ticket (ticket_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


CREATE TABLE IF NOT EXISTS ticket_ai_handoffs (
 ticket_id INT NOT NULL PRIMARY KEY,
 requested_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Apply once before enabling storage. Existing BLOBs are retained.
CREATE TABLE IF NOT EXISTS ticket_media_objects (
 media_id int(11) NOT NULL,
 bucket varchar(63) NOT NULL,
 object_key varchar(255) NOT NULL,
 PRIMARY KEY (media_id),
 UNIQUE KEY ticket_object_key (bucket,object_key),
 CONSTRAINT fk_ticket_object_media FOREIGN KEY (media_id)
 REFERENCES ticket_media(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS ticket_telegram_links (
 profile VARCHAR(100) NOT NULL,
 chat_id BIGINT NOT NULL,
 telegram_message_id BIGINT NOT NULL,
 ticket_id INT NOT NULL,
 user_id INT NOT NULL,
 PRIMARY KEY(profile,chat_id,telegram_message_id),
 KEY ticket_reply_owner(user_id,ticket_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS ticket_telegram_received (
 profile VARCHAR(100) NOT NULL,
 chat_id BIGINT NOT NULL,
 telegram_message_id BIGINT NOT NULL,
 ticket_id INT NOT NULL,
 PRIMARY KEY(profile,chat_id,telegram_message_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Add absent non-key fields without replacing existing values.
SET @vbios_ddl = IF(EXISTS(SELECT 1 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='tickets' AND COLUMN_NAME='user_id'), 'SELECT 1', 'ALTER TABLE `tickets` ADD COLUMN `user_id` int(11) NOT NULL');
PREPARE vbios_stmt FROM @vbios_ddl;
EXECUTE vbios_stmt;
DEALLOCATE PREPARE vbios_stmt;

SET @vbios_ddl = IF(EXISTS(SELECT 1 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='tickets' AND COLUMN_NAME='user_service_id'), 'SELECT 1', 'ALTER TABLE `tickets` ADD COLUMN `user_service_id` int(11) DEFAULT NULL');
PREPARE vbios_stmt FROM @vbios_ddl;
EXECUTE vbios_stmt;
DEALLOCATE PREPARE vbios_stmt;

SET @vbios_ddl = IF(EXISTS(SELECT 1 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='tickets' AND COLUMN_NAME='created'), 'SELECT 1', 'ALTER TABLE `tickets` ADD COLUMN `created` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP');
PREPARE vbios_stmt FROM @vbios_ddl;
EXECUTE vbios_stmt;
DEALLOCATE PREPARE vbios_stmt;

SET @vbios_ddl = IF(EXISTS(SELECT 1 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='tickets' AND COLUMN_NAME='updated'), 'SELECT 1', 'ALTER TABLE `tickets` ADD COLUMN `updated` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP');
PREPARE vbios_stmt FROM @vbios_ddl;
EXECUTE vbios_stmt;
DEALLOCATE PREPARE vbios_stmt;

SET @vbios_ddl = IF(EXISTS(SELECT 1 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='tickets' AND COLUMN_NAME='closed_at'), 'SELECT 1', 'ALTER TABLE `tickets` ADD COLUMN `closed_at` datetime DEFAULT NULL');
PREPARE vbios_stmt FROM @vbios_ddl;
EXECUTE vbios_stmt;
DEALLOCATE PREPARE vbios_stmt;

SET @vbios_ddl = IF(EXISTS(SELECT 1 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='tickets' AND COLUMN_NAME='telegram_chat_id'), 'SELECT 1', 'ALTER TABLE `tickets` ADD COLUMN `telegram_chat_id` bigint DEFAULT NULL');
PREPARE vbios_stmt FROM @vbios_ddl;
EXECUTE vbios_stmt;
DEALLOCATE PREPARE vbios_stmt;

SET @vbios_ddl = IF(EXISTS(SELECT 1 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='tickets' AND COLUMN_NAME='telegram_thread_id'), 'SELECT 1', 'ALTER TABLE `tickets` ADD COLUMN `telegram_thread_id` int(11) DEFAULT NULL');
PREPARE vbios_stmt FROM @vbios_ddl;
EXECUTE vbios_stmt;
DEALLOCATE PREPARE vbios_stmt;

SET @vbios_ddl = IF(EXISTS(SELECT 1 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ticket_messages' AND COLUMN_NAME='user_id'), 'SELECT 1', 'ALTER TABLE `ticket_messages` ADD COLUMN `user_id` int(11) NOT NULL DEFAULT 0');
PREPARE vbios_stmt FROM @vbios_ddl;
EXECUTE vbios_stmt;
DEALLOCATE PREPARE vbios_stmt;

SET @vbios_ddl = IF(EXISTS(SELECT 1 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ticket_messages' AND COLUMN_NAME='is_admin'), 'SELECT 1', 'ALTER TABLE `ticket_messages` ADD COLUMN `is_admin` tinyint(1) NOT NULL DEFAULT 0');
PREPARE vbios_stmt FROM @vbios_ddl;
EXECUTE vbios_stmt;
DEALLOCATE PREPARE vbios_stmt;

SET @vbios_ddl = IF(EXISTS(SELECT 1 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ticket_messages' AND COLUMN_NAME='message'), 'SELECT 1', 'ALTER TABLE `ticket_messages` ADD COLUMN `message` text NOT NULL');
PREPARE vbios_stmt FROM @vbios_ddl;
EXECUTE vbios_stmt;
DEALLOCATE PREPARE vbios_stmt;

SET @vbios_ddl = IF(EXISTS(SELECT 1 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ticket_messages' AND COLUMN_NAME='created'), 'SELECT 1', 'ALTER TABLE `ticket_messages` ADD COLUMN `created` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP');
PREPARE vbios_stmt FROM @vbios_ddl;
EXECUTE vbios_stmt;
DEALLOCATE PREPARE vbios_stmt;

SET @vbios_ddl = IF(EXISTS(SELECT 1 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ticket_media' AND COLUMN_NAME='user_id'), 'SELECT 1', 'ALTER TABLE `ticket_media` ADD COLUMN `user_id` int(11) NOT NULL');
PREPARE vbios_stmt FROM @vbios_ddl;
EXECUTE vbios_stmt;
DEALLOCATE PREPARE vbios_stmt;

SET @vbios_ddl = IF(EXISTS(SELECT 1 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ticket_media' AND COLUMN_NAME='size'), 'SELECT 1', 'ALTER TABLE `ticket_media` ADD COLUMN `size` int(11) NOT NULL');
PREPARE vbios_stmt FROM @vbios_ddl;
EXECUTE vbios_stmt;
DEALLOCATE PREPARE vbios_stmt;

SET @vbios_ddl = IF(EXISTS(SELECT 1 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ticket_media' AND COLUMN_NAME='data'), 'SELECT 1', 'ALTER TABLE `ticket_media` ADD COLUMN `data` mediumblob NOT NULL');
PREPARE vbios_stmt FROM @vbios_ddl;
EXECUTE vbios_stmt;
DEALLOCATE PREPARE vbios_stmt;

SET @vbios_ddl = IF(EXISTS(SELECT 1 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ticket_media' AND COLUMN_NAME='created'), 'SELECT 1', 'ALTER TABLE `ticket_media` ADD COLUMN `created` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP');
PREPARE vbios_stmt FROM @vbios_ddl;
EXECUTE vbios_stmt;
DEALLOCATE PREPARE vbios_stmt;

SET @vbios_ddl = IF(EXISTS(SELECT 1 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ticket_ai_jobs' AND COLUMN_NAME='answer'), 'SELECT 1', 'ALTER TABLE `ticket_ai_jobs` ADD COLUMN answer MEDIUMTEXT NULL');
PREPARE vbios_stmt FROM @vbios_ddl;
EXECUTE vbios_stmt;
DEALLOCATE PREPARE vbios_stmt;

SET @vbios_ddl = IF(EXISTS(SELECT 1 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ticket_ai_jobs' AND COLUMN_NAME='reply_message_id'), 'SELECT 1', 'ALTER TABLE `ticket_ai_jobs` ADD COLUMN reply_message_id INT NULL');
PREPARE vbios_stmt FROM @vbios_ddl;
EXECUTE vbios_stmt;
DEALLOCATE PREPARE vbios_stmt;

SET @vbios_ddl = IF(EXISTS(SELECT 1 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ticket_ai_jobs' AND COLUMN_NAME='created'), 'SELECT 1', 'ALTER TABLE `ticket_ai_jobs` ADD COLUMN created DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP');
PREPARE vbios_stmt FROM @vbios_ddl;
EXECUTE vbios_stmt;
DEALLOCATE PREPARE vbios_stmt;

SET @vbios_ddl = IF(EXISTS(SELECT 1 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ticket_ai_handoffs' AND COLUMN_NAME='requested_at'), 'SELECT 1', 'ALTER TABLE `ticket_ai_handoffs` ADD COLUMN requested_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP');
PREPARE vbios_stmt FROM @vbios_ddl;
EXECUTE vbios_stmt;
DEALLOCATE PREPARE vbios_stmt;

SET @vbios_ddl = IF(EXISTS(SELECT 1 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ticket_telegram_links' AND COLUMN_NAME='user_id'), 'SELECT 1', 'ALTER TABLE `ticket_telegram_links` ADD COLUMN user_id INT NOT NULL');
PREPARE vbios_stmt FROM @vbios_ddl;
EXECUTE vbios_stmt;
DEALLOCATE PREPARE vbios_stmt;

SET @vbios_ddl = IF(EXISTS(SELECT 1 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='tickets' AND COLUMN_NAME='subject'), 'SELECT 1', 'ALTER TABLE `tickets` ADD COLUMN `subject` varchar(160) NOT NULL');
PREPARE vbios_stmt FROM @vbios_ddl;
EXECUTE vbios_stmt;
DEALLOCATE PREPARE vbios_stmt;

SET @vbios_ddl = IF(EXISTS(SELECT 1 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='tickets' AND COLUMN_NAME='status'), 'SELECT 1', 'ALTER TABLE `tickets` ADD COLUMN `status` varchar(16) NOT NULL DEFAULT ''open''');
PREPARE vbios_stmt FROM @vbios_ddl;
EXECUTE vbios_stmt;
DEALLOCATE PREPARE vbios_stmt;

SET @vbios_ddl = IF(EXISTS(SELECT 1 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='tickets' AND COLUMN_NAME='priority'), 'SELECT 1', 'ALTER TABLE `tickets` ADD COLUMN `priority` varchar(16) NOT NULL DEFAULT ''normal''');
PREPARE vbios_stmt FROM @vbios_ddl;
EXECUTE vbios_stmt;
DEALLOCATE PREPARE vbios_stmt;

SET @vbios_ddl = IF(EXISTS(SELECT 1 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='tickets' AND COLUMN_NAME='ticket_type'), 'SELECT 1', 'ALTER TABLE `tickets` ADD COLUMN `ticket_type` varchar(16) NOT NULL DEFAULT ''other''');
PREPARE vbios_stmt FROM @vbios_ddl;
EXECUTE vbios_stmt;
DEALLOCATE PREPARE vbios_stmt;

SET @vbios_ddl = IF(EXISTS(SELECT 1 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='tickets' AND COLUMN_NAME='telegram_error'), 'SELECT 1', 'ALTER TABLE `tickets` ADD COLUMN `telegram_error` varchar(255) DEFAULT NULL');
PREPARE vbios_stmt FROM @vbios_ddl;
EXECUTE vbios_stmt;
DEALLOCATE PREPARE vbios_stmt;

SET @vbios_ddl = IF(EXISTS(SELECT 1 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ticket_media' AND COLUMN_NAME='name'), 'SELECT 1', 'ALTER TABLE `ticket_media` ADD COLUMN `name` varchar(255) NOT NULL');
PREPARE vbios_stmt FROM @vbios_ddl;
EXECUTE vbios_stmt;
DEALLOCATE PREPARE vbios_stmt;

SET @vbios_ddl = IF(EXISTS(SELECT 1 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ticket_media' AND COLUMN_NAME='mime_type'), 'SELECT 1', 'ALTER TABLE `ticket_media` ADD COLUMN `mime_type` varchar(100) DEFAULT NULL');
PREPARE vbios_stmt FROM @vbios_ddl;
EXECUTE vbios_stmt;
DEALLOCATE PREPARE vbios_stmt;

SET @vbios_ddl = IF(EXISTS(SELECT 1 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ticket_ai_jobs' AND COLUMN_NAME='status'), 'SELECT 1', 'ALTER TABLE `ticket_ai_jobs` ADD COLUMN status VARCHAR(16) NOT NULL');
PREPARE vbios_stmt FROM @vbios_ddl;
EXECUTE vbios_stmt;
DEALLOCATE PREPARE vbios_stmt;

SET @vbios_ddl = IF(EXISTS(SELECT 1 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ticket_media_objects' AND COLUMN_NAME='bucket'), 'SELECT 1', 'ALTER TABLE `ticket_media_objects` ADD COLUMN bucket varchar(63) NOT NULL');
PREPARE vbios_stmt FROM @vbios_ddl;
EXECUTE vbios_stmt;
DEALLOCATE PREPARE vbios_stmt;

SET @vbios_ddl = IF(EXISTS(SELECT 1 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ticket_media_objects' AND COLUMN_NAME='object_key'), 'SELECT 1', 'ALTER TABLE `ticket_media_objects` ADD COLUMN object_key varchar(255) NOT NULL');
PREPARE vbios_stmt FROM @vbios_ddl;
EXECUTE vbios_stmt;
DEALLOCATE PREPARE vbios_stmt;

-- Older AI packages used VARCHAR(100); widen only short VARCHAR error fields.
SET @vbios_ddl = IF(EXISTS(SELECT 1 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ticket_ai_jobs' AND COLUMN_NAME='error' AND DATA_TYPE='varchar' AND CHARACTER_MAXIMUM_LENGTH < 255), 'ALTER TABLE ticket_ai_jobs MODIFY COLUMN error VARCHAR(255) NULL', 'SELECT 1');
PREPARE vbios_stmt FROM @vbios_ddl;
EXECUTE vbios_stmt;
DEALLOCATE PREPARE vbios_stmt;
SELECT 'vBios ticket schema migration completed' AS result;

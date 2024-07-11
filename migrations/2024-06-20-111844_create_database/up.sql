-- Your SQL goes here
CREATE TABLE `hosts`(
	`id` INTEGER NOT NULL PRIMARY KEY,
	`name` TEXT NOT NULL,
	`hostname` TEXT NOT NULL,
	`port` SMALLINT NOT NULL
);

CREATE TABLE `users`(
	`id` INTEGER NOT NULL PRIMARY KEY,
	`username` TEXT NOT NULL,
	`enabled`  BOOLEAN NOT NULL CHECK (enabled IN (0, 1)) DEFAULT 0
);

CREATE TABLE `user_in_host`(
	`id` INTEGER NOT NULL PRIMARY KEY,
	`host_id` INTEGER,
	`user_id` INTEGER,
	`options` TEXT,
	FOREIGN KEY (`host_id`) REFERENCES `hosts`(`id`),
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`)
);

CREATE TABLE `groups`(
	`id` INTEGER NOT NULL PRIMARY KEY,
	`name` TEXT NOT NULL
);

CREATE TABLE `keys`(
	`id` INTEGER NOT NULL PRIMARY KEY,
	`key_type` TEXT NOT NULL,
	`key_base64` TEXT NOT NULL,
	`comment` TEXT,
	`host_id` INTEGER,
	`user_id` INTEGER,
	FOREIGN KEY (`host_id`) REFERENCES `hosts`(`id`),
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`)
);

diesel::table! {
    /// All hosts
    host (id) {
        /// unique id
        id -> Integer,
        /// display name
        name -> Text,
        /// username for ssh connections
        username -> Text,
        /// hostname or ip address for ssh connections
        address -> Text,
        /// port for ssh connections
        port -> Integer,
        /// fingerprint of the hostkey
        key_fingerprint -> Nullable<Text>,
        /// jumphost for ssh connections
        jump_via -> Nullable<Integer>,
        /// whether this host is disabled
        disabled -> Bool,
        /// optional comment for this host
        comment -> Nullable<Text>,
    }
}

diesel::table! {
    /// All users
    user (id) {
        /// unique id
        id -> Integer,
        /// name of this user
        username -> Text,
        /// whether this user is active
        enabled -> Bool,
        /// optional comment for this user
        comment -> Nullable<Text>,
    }
}

diesel::joinable!(authorization -> host (host_id));
diesel::joinable!(authorization -> user (user_id));
diesel::table! {
    /// User authorizations
    authorization (id) {
        /// unique id
        id -> Integer,
        /// host
        host_id -> Integer,
        /// user
        user_id -> Integer,
        /// username on the host
        login -> Text,
        /// ssh key options
        options -> Nullable<Text>,
        /// optional comment for this authorization
        comment -> Nullable<Text>,
    }
}

diesel::joinable!(user_key -> user (user_id));
diesel::table! {
    /// All user ssh public keys
    user_key (id) {
        /// unique id
        id -> Integer,
        /// key type
        key_type -> Text,
        /// base64 encoded public key
        key_base64 -> Text,
        /// key name (renamed from comment)
        name -> Nullable<Text>,
        /// additional comment for the key
        extra_comment -> Nullable<Text>,
        /// user this key belongs to
        user_id -> Integer,
    }
}


diesel::joinable!(activity_log -> user (user_id));
diesel::table! {
    /// Activity log for tracking system actions
    activity_log (id) {
        /// unique id
        id -> Integer,
        /// type of activity: 'key', 'host', 'user', or 'auth'
        activity_type -> Text,
        /// action performed
        action -> Text,
        /// target of the action
        target -> Text,
        /// user associated with the action (can be null)
        user_id -> Nullable<Integer>,
        /// username of the actor performing the action
        actor_username -> Text,
        /// unix timestamp of when the action occurred
        timestamp -> Integer,
        /// optional JSON metadata
        metadata -> Nullable<Text>,
    }
}

diesel::allow_tables_to_appear_in_same_query!(host, user, authorization, user_key, activity_log,);

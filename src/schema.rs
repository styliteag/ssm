diesel::table! {
    /// All hosts
    host (id) {
        /// The unique id
        id -> Integer,
        /// The frienddly name
        name -> Text,
        /// The username for ssh connections
        username -> Text,
        /// The hostname or ip address for ssh connections
        hostname -> Text,
        /// The port for ssh connections
        port -> Integer,
        /// The fingerprint of the hostkey
        key_fingerprint -> Text,
        /// The jumphost for ssh connections
        jump_via -> Nullable<Integer>,
    }
}

diesel::table! {
    /// All users
    user (id) {
        /// The unique id
        id -> Integer,
        /// The name of this user
        username -> Text,
        /// Whether this user is active
        enabled -> Bool,
    }
}

diesel::joinable!(user_in_host -> host (host_id));
diesel::joinable!(user_in_host -> user (user_id));
diesel::table! {
    /// A user is allowed on a host
    user_in_host (id) {
        /// The unique id
        id -> Integer,
        /// The host
        host_id -> Integer,
        /// The user
        user_id -> Integer,
        /// The username on the host
        user -> Text,
        /// The ssh key options
        options -> Nullable<Text>,
    }
}

diesel::joinable!(user_key -> user (user_id));
diesel::table! {
    /// All user ssh public keys
    user_key (id) {
        /// The unique id
        id -> Integer,
        /// The ssh key type
        key_type -> Text,
        /// The ssh key base64
        key_base64 -> Text,
        /// The ssh key comment
        comment -> Nullable<Text>,
        /// The user this key belongs to
        user_id -> Integer,
    }
}

diesel::allow_tables_to_appear_in_same_query!(host, user, user_in_host, user_key,);

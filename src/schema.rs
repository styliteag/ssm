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
        key_fingerprint -> Text,
        /// jumphost for ssh connections
        jump_via -> Nullable<Integer>,
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
    }
}

diesel::joinable!(user_in_host -> host (host_id));
diesel::joinable!(user_in_host -> user (user_id));
diesel::table! {
    /// User authorizations
    user_in_host (id) {
        /// unique id
        id -> Integer,
        /// host
        host_id -> Integer,
        /// user
        user_id -> Integer,
        /// username on the host
        user -> Text,
        /// ssh key options
        options -> Nullable<Text>,
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
        /// optional comment
        comment -> Nullable<Text>,
        /// user this key belongs to
        user_id -> Integer,
    }
}

diesel::allow_tables_to_appear_in_same_query!(host, user, user_in_host, user_key,);

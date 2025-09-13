// API Response Types
export interface ApiResponse<T> {
  success: boolean;
  data?: T;
  message?: string;
}

export interface ApiError {
  success: boolean;
  message: string;
}

// Authentication Types
export interface LoginRequest {
  username: string;
  password: string;
}

export interface TokenResponse {
  token: string;
  expires_in: number;
}

export interface AuthStatusResponse {
  logged_in: boolean;
  username?: string;
}

// Pagination Types
export interface PaginationQuery {
  page?: number;
  per_page?: number;
}

export interface PaginatedResponse<T> {
  items: T[];
  total: number;
  page: number;
  per_page: number;
  total_pages: number;
}

// Core Data Models
export interface Host {
  id: number;
  name: string;
  username: string;
  address: string;
  port: number;
  key_fingerprint?: string;
  jump_via?: number;
  jumphost_name?: string;
  connection_status: string;
  connection_error?: string;
  authorizations: Array<{ id: number; username: string; login: string; options?: string }>;
  disabled: boolean;
  comment?: string;
}

export interface NewHost {
  name: string;
  address: string;
  port: number;
  username: string;
  key_fingerprint: string;
  jump_via?: number;
  disabled?: boolean;
  comment?: string;
}

export interface User {
  id: number;
  username: string;
  enabled: boolean;
  comment?: string;
}

export interface NewUser {
  username: string;
  comment?: string;
}

export interface PublicUserKey {
  id: number;
  key_type: string;
  key_base64: string;
  key_name?: string;
  extra_comment?: string;
  user_id: number;
}

export interface NewPublicUserKey {
  key_type: string;
  key_base64: string;
  key_name?: string;
  extra_comment?: string;
  user_id: number;
}

export interface Authorization {
  id: number;
  host_id: number;
  user_id: number;
  login: string;
  options?: string;
  comment?: string;
}

// Raw authorization response from API (before mapping to proper Authorization format)
export interface RawAuthorizationResponse {
  id: number;
  username: string; // This is actually the hostname
  login: string;
  options?: string;
  comment?: string;
}

export interface NewAuthorization {
  host_id: number;
  user_id: number;
  login: string;
  options?: string;
  comment?: string;
}

// Extended types for UI
export interface HostWithJumpHost extends Host {
  jump_host?: Host;
}

export interface UserWithKeys extends User {
  keys: PublicUserKey[];
}

export interface AuthorizationWithDetails extends Authorization {
  host: Host;
  user: User;
}

// Allowed user on host (from backend AllowedUserOnHost)
export interface AllowedUserOnHost {
  key: PublicUserKey;
  login: string;
  username: string;
  options?: string;
}

// Form data types
export interface HostFormData {
  name: string;
  address: string;
  port: number;
  username: string;
  key_fingerprint?: string;
  jump_via?: string | number;
  disabled?: boolean;
  comment?: string;
}

export interface UserFormData {
  username: string;
  enabled?: boolean;
  comment?: string;
}

export interface KeyFormData {
  key_type: string;
  key_base64: string;
  key_name?: string;
  extra_comment?: string;
}

export interface AuthorizationFormData {
  host_id: number;
  user_id: number;
  login: string;
  options?: string;
  comment?: string;
}

// Filter and search types
export interface HostFilters {
  search?: string;
  enabled?: boolean;
}

export interface UserFilters {
  search?: string;
  enabled?: boolean;
}

export interface KeyFilters {
  search?: string;
  user_id?: number;
}

// SSH Key difference types (for diff functionality)
export interface KeyDifference {
  action: 'add' | 'remove' | 'modify';
  key: AllowedUserOnHost;
  existing_key?: AllowedUserOnHost;
  line_number?: number;
}

export interface HostKeyDifferences {
  host: Host;
  differences: KeyDifference[];
}

// Diff viewer types
export interface DiffLine {
  type: 'added' | 'removed' | 'unchanged' | 'modified';
  content: string;
  line_number_old?: number;
  line_number_new?: number;
  key_fingerprint?: string;
}

export interface FileDiff {
  expected_content: string;
  actual_content: string;
  lines: DiffLine[];
  summary: {
    added: number;
    removed: number;
    modified: number;
    unchanged: number;
  };
}

export interface HostDiffStatus {
  host_id: number;
  host: Host;
  status: 'synchronized' | 'out_of_sync' | 'error' | 'unknown';
  last_checked?: string;
  error_message?: string;
  file_diff?: FileDiff;
  key_differences?: KeyDifference[];
  difference_count: number;
  [key: string]: unknown;
}

export interface DiffDeployment {
  host_id: number;
  selected_differences: KeyDifference[];
  create_backup: boolean;
  dry_run: boolean;
}

export interface DeploymentResult {
  host_id: number;
  success: boolean;
  message: string;
  backup_file?: string;
  deployed_keys?: number;
  errors?: string[];
}

export interface BatchDeploymentStatus {
  total_hosts: number;
  completed_hosts: number;
  successful_deploys: number;
  failed_deploys: number;
  results: DeploymentResult[];
  in_progress: boolean;
}

// Filter types for diff page
export interface DiffPageFilters {
  status?: 'all' | 'out_of_sync' | 'error' | 'synchronized';
  search?: string;
  show_zero_diff?: boolean;
}

// Deployment history types
export interface DeploymentHistoryEntry {
  id: number;
  host_id: number;
  host_name: string;
  timestamp: string;
  user?: string;
  keys_deployed: number;
  backup_file?: string;
  success: boolean;
  message?: string;
}

// Theme and UI types
export type Theme = 'light' | 'dark';

export interface NotificationState {
  id: string;
  type: 'success' | 'error' | 'warning' | 'info';
  title: string;
  message?: string;
  duration?: number;
}

// Navigation types
export interface NavigationItem {
  label: string;
  path: string;
  icon: string;
  requiresAuth: boolean;
}

// Table sorting and pagination
export interface SortConfig {
  key: string;
  direction: 'asc' | 'desc';
}

export interface TableConfig {
  sortable: boolean;
  searchable: boolean;
  paginated: boolean;
  defaultSort?: SortConfig;
}
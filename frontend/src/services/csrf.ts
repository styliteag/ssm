// CSRF token management
let csrfToken: string | null = null;

export const setCsrfToken = (token: string) => {
  csrfToken = token;
  console.log('CSRF Token set:', token); // Debug log
};

export const getCsrfToken = (): string | null => {
  console.log('Getting CSRF Token:', csrfToken); // Debug log
  return csrfToken;
};

export const clearCsrfToken = () => {
  csrfToken = null;
  console.log('CSRF Token cleared'); // Debug log
};

// Debug function - remove in production
export const debugCsrfToken = () => {
  console.log('Current CSRF Token:', csrfToken);
  return csrfToken;
};

// Expose debug function to window for browser console access
if (typeof window !== 'undefined') {
  (window as any).debugCsrfToken = debugCsrfToken;
  (window as any).getCsrfTokenDebug = getCsrfToken;
}
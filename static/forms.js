// Theme management
class ThemeManager {
  constructor() {
    this.init();
  }

  init() {
    // Get stored theme or default to system preference
    const storedTheme = localStorage.getItem('theme');
    const systemPrefersDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
    
    if (storedTheme) {
      this.setTheme(storedTheme);
    } else if (systemPrefersDark) {
      this.setTheme('dark');
    } else {
      this.setTheme('light');
    }

    // Listen for system theme changes when no manual override
    window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', (e) => {
      if (!localStorage.getItem('theme')) {
        this.setTheme(e.matches ? 'dark' : 'light');
      }
    });
  }

  setTheme(theme) {
    document.documentElement.setAttribute('data-theme', theme);
    this.updateToggleButton(theme);
  }

  toggleTheme() {
    const currentTheme = document.documentElement.getAttribute('data-theme') || 'light';
    const newTheme = currentTheme === 'light' ? 'dark' : 'light';
    
    this.setTheme(newTheme);
    localStorage.setItem('theme', newTheme);
  }

  updateToggleButton(theme) {
    const button = document.querySelector('.theme-toggle');
    if (button) {
      const icon = button.querySelector('.theme-icon');
      const text = button.querySelector('.theme-text');
      
      if (theme === 'dark') {
        icon.textContent = '☀️';
        text.textContent = 'Light';
        button.setAttribute('aria-label', 'Switch to light theme');
      } else {
        icon.textContent = '🌙';
        text.textContent = 'Dark';
        button.setAttribute('aria-label', 'Switch to dark theme');
      }
    }
  }
}

// Initialize theme manager when DOM is loaded
document.addEventListener('DOMContentLoaded', () => {
  window.themeManager = new ThemeManager();
  initializeSearchableSelects();
});

// Reinitialize searchable selects when HTMX loads new content
document.addEventListener('htmx:afterSettle', () => {
  initializeSearchableSelects();
});

// Searchable select functionality
function initializeSearchableSelects() {
  // Initialize jumphost searchable select
  const jumphostInput = document.getElementById('jumphost_selection');
  const jumphostValue = document.getElementById('jumphost_value');
  const jumphostList = document.getElementById('jumphost_list');
  
  if (jumphostInput && jumphostValue && jumphostList) {
    setupSearchableSelect(jumphostInput, jumphostValue, jumphostList);
  }
}

function setupSearchableSelect(input, hiddenInput, datalist) {
  // Handle input change to update hidden field
  input.addEventListener('input', () => {
    const value = input.value.trim();
    const options = datalist.querySelectorAll('option');
    let foundId = '-1'; // Default to "none"
    
    // Find matching option
    for (const option of options) {
      if (option.value.toLowerCase() === value.toLowerCase()) {
        foundId = option.getAttribute('data-id');
        break;
      }
    }
    
    hiddenInput.value = foundId;
  });
  
  // Handle selection from datalist
  input.addEventListener('change', () => {
    const value = input.value.trim();
    const options = datalist.querySelectorAll('option');
    
    // Check if it's a valid selection
    let found = false;
    for (const option of options) {
      if (option.value.toLowerCase() === value.toLowerCase()) {
        hiddenInput.value = option.getAttribute('data-id');
        found = true;
        break;
      }
    }
    
    // If not found and not empty, reset
    if (!found && value !== '') {
      input.value = '';
      hiddenInput.value = '-1';
    }
  });
  
  // Clear selection when input is empty
  input.addEventListener('blur', () => {
    if (input.value.trim() === '') {
      hiddenInput.value = '-1';
    }
  });
}

const form_response_dialog = document.querySelector("#form_response_dialog");
const snackbar = document.querySelector("#snackbar");
const modal_stack = document.getElementById("modal_stack");
let lastXhr = "";

/* Remove all children of elem */
function removeChildren(elem) {
  while (elem.firstChild) {
    elem.removeChild(elem.firstChild);
  }
}

/* Closes the current modal, and returns wether all Modals are closed */
function closeModal(force = false) {
  if (force) {
    removeChildren(modal_stack);
  }

  if (modal_stack.childElementCount > 0) {
    removeChildren(form_response_dialog);

    const stackPop = modal_stack.lastChild;
    while (stackPop.firstChild) {
      form_response_dialog.appendChild(
        stackPop.removeChild(stackPop.firstChild),
      );
    }
    htmx.remove(stackPop);
    return false;
  }

  form_response_dialog.close();
  return true;
}

/* Appends a toast to the snackbar list */
function show_response_toast(html, is_success) {
  const div = document.createElement("div");
  div.className = is_success ? "form_success" : "form_error";

  const template = document.createElement("template");
  template.innerHTML = html;
  const node = template.content.cloneNode(true);
  div.appendChild(node);

  setTimeout(() => {
    htmx.remove(div);
  }, 5000);

  snackbar.prepend(div);
}

htmx.on("htmx:afterRequest", (event) => {
  // Prevent event from triggering twice.
  // This seems to be an htmx bug?
  if (lastXhr === event.detail.xhr) return;
  lastXhr = event.detail.xhr;

  const isFormResponse =
    event.detail.xhr.getResponseHeader("X-FORM") === "true";
  const isSuccess = event.detail.successful === true;
  if (!isSuccess) {
    if (isFormResponse) {
      show_response_toast(event.detail.xhr.response, false);
    } else {
      const statusCode = event.detail.xhr.status;
      show_response_toast(`<b>Request Failed</b><br><i>
        ${
          typeof statusCode === "number" && statusCode !== 0
            ? `Status code: <code>${statusCode}</code></i>`
            : "No details"
        }`);
    }
    return;
  }

  if (!isFormResponse) return;

  const modal_header = event.detail.xhr.getResponseHeader("X-MODAL");
  // When modal_header is null we pop the stack, when close we force-close
  if (modal_header !== "open") {
    closeModal(modal_header === "close") &&
      show_response_toast(event.detail.xhr.response, true);
    return;
  }
  const is_open = form_response_dialog.open;

  if (is_open) {
    const new_stack_entry = document.createElement("div");
    while (form_response_dialog.firstChild) {
      new_stack_entry.appendChild(
        form_response_dialog.removeChild(form_response_dialog.firstChild),
      );
    }
    modal_stack.appendChild(new_stack_entry);
  }

  htmx.swap(form_response_dialog, event.detail.xhr.response, {
    swapStyle: "innerHTML",
  });

  if (!is_open) {
    form_response_dialog.showModal();
  }
});

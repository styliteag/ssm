const form_response_dialog = document.querySelector("#form_response_dialog");
const snackbar = document.querySelector("#snackbar");
const modal_stack = document.getElementById("modal_stack");
let lastXhr = "";

/* Closes the current modal, and returns wether all Modals are closed */
function closeModal() {
  if (modal_stack.childElementCount > 0) {
    while (form_response_dialog.firstChild) {
      form_response_dialog.removeChild(form_response_dialog.firstChild);
    }

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

  const doOpenModal = event.detail.xhr.getResponseHeader("X-MODAL") === "open";
  if (!doOpenModal) {
    closeModal() && show_response_toast(event.detail.xhr.response, true);
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

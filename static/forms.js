const form_response_dialog = document.querySelector("#form_response_dialog");
const snackbar = document.querySelector("#snackbar");

function closeModal() {
  form_response_dialog.close();
}

function show_response(html, is_success) {
  const div = document.createElement('div');
  div.className = is_success ? "form_success" : "form_error";

  const template = document.createElement('template');
  template.innerHTML = html;
  const node = template.content.cloneNode(true);
  div.appendChild(node);

  setTimeout(() => {
    div.remove();
  }, 5000)

  snackbar.appendChild(div);
}

document.body.addEventListener("htmx:afterRequest", (event) => {
  const isFormResponse = (event.detail.xhr.getResponseHeader("X-FORM") === "true");
  const isSuccess = (event.detail.successful === true);
  if (!isSuccess) {
    if (isFormResponse) {
      show_response(event.detail.xhr.response, false);
    } else {
      const statusCode = event.detail.xhr.status;
      show_response(`<b>Request Failed</b><br><i>
        ${(typeof statusCode === "number" && statusCode !== 0) ?
          `Status code: <code>${statusCode}</code></i>` :
          "No details"
        }`)
    }
    return;
  }

  if (!isFormResponse) return;

  const openModal = (event.detail.xhr.getResponseHeader("X-MODAL") === "open");
  if (openModal) {
    form_response_dialog.innerHTML = event.detail.xhr.response;
    htmx.process(form_response_dialog);
    form_response_dialog.showModal();
    return;
  }
  closeModal();

  show_response(event.detail.xhr.response, true);
});

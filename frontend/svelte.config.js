import { vitePreprocess } from "@sveltejs/vite-plugin-svelte";

function isShoelaceButtonA11yFalsePositive(warning) {
  if (!warning || typeof warning !== "object") {
    return false;
  }

  const suppressibleCode =
    warning.code === "a11y_click_events_have_key_events" ||
    warning.code === "a11y_no_static_element_interactions";

  return suppressibleCode && warning.message.includes("<sl-button>");
}

const config = {
  preprocess: vitePreprocess(),
  onwarn(warning, defaultHandler) {
    if (isShoelaceButtonA11yFalsePositive(warning)) {
      return;
    }

    defaultHandler(warning);
  }
};

export default config;

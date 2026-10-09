import App from "./App.svelte";
import { mount } from "svelte";
import { setBasePath } from "@shoelace-style/shoelace/dist/utilities/base-path.js";
import "@shoelace-style/shoelace/dist/themes/light.css";
import "./app.css";

setBasePath("/node_modules/@shoelace-style/shoelace/dist/");

const app = mount(App, {
  target: document.getElementById("app")!
});

export default app;

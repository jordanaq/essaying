import { fireEvent, render, screen, waitFor, within } from "@testing-library/svelte";
import { describe, expect, it, vi } from "vitest";
import type { Editor } from "@tiptap/core";
import MarkdownEditor from "./MarkdownEditor.svelte";

const label = "Draft";
const toggle = () => screen.getByRole("button", { name: "Raw Markdown for Draft" });
const textbox = () => screen.getByRole("textbox", { name: label });
// Tiptap exposes the live editor on its DOM node for selection-based tests.
const instance = () => (textbox() as HTMLElement & { editor: Editor }).editor;

describe("Markdown editor", () => {
  it("defaults to rendered Markdown with bold, headings, and both kinds of lists", () => {
    const onChange = vi.fn();
    render(MarkdownEditor, { label, value: "# A heading\n\n**Bold** and *italic*\n\n- Bullet\n\n1. Number", onChange });
    const editor = textbox();
    expect(editor).toHaveAttribute("contenteditable", "true");
    expect(within(editor).getByRole("heading", { name: "A heading" })).toBeInTheDocument();
    expect(editor.querySelector("strong")).toHaveTextContent("Bold");
    expect(editor.querySelector("em")).toHaveTextContent("italic");
    expect(editor.querySelector("ul li")).toHaveTextContent("Bullet");
    expect(editor.querySelector("ol li")).toHaveTextContent("Number");
    expect(toggle()).toHaveAttribute("aria-pressed", "false");
    expect(onChange).not.toHaveBeenCalled();
  });

  it("switches views without normalizing the source or emitting an edit", async () => {
    const value = "Title\n=====\n\n__bold__\n\n* first\n* second\n\n";
    const onChange = vi.fn();
    render(MarkdownEditor, { label, value, onChange });
    await fireEvent.click(toggle());
    expect(textbox()).toHaveValue(value);
    expect(screen.queryByRole("button", { name: "Bold" })).not.toBeInTheDocument();
    await fireEvent.click(toggle());
    expect(textbox().querySelector("strong")).toHaveTextContent("bold");
    expect(onChange).not.toHaveBeenCalled();
  });

  it("keeps raw edits when returning to rendered mode", async () => {
    const onChange = vi.fn();
    render(MarkdownEditor, { label, value: "Original", onChange });
    await fireEvent.click(toggle());
    await fireEvent.input(textbox(), { target: { value: "## Updated\n\n1. First\n2. Second" } });
    expect(onChange).toHaveBeenLastCalledWith("## Updated\n\n1. First\n2. Second");
    await fireEvent.click(toggle());
    expect(within(textbox()).getByRole("heading", { name: "Updated", level: 2 })).toBeInTheDocument();
    expect(textbox().querySelectorAll("ol li")).toHaveLength(2);
  });

  it("formats selected text with Ctrl+B and Ctrl+I and supports undo/redo", async () => {
    const onChange = vi.fn();
    render(MarkdownEditor, { label, value: "An argument", onChange });
    instance().commands.selectAll();
    await fireEvent.keyDown(textbox(), { key: "b", ctrlKey: true });
    expect(textbox().querySelector("strong")).toHaveTextContent("An argument");
    expect(onChange).toHaveBeenLastCalledWith("**An argument**");
    expect(screen.getByRole("button", { name: "Bold" })).toHaveAttribute("aria-pressed", "true");
    await fireEvent.keyDown(textbox(), { key: "i", ctrlKey: true });
    expect(textbox().querySelector("em")).toHaveTextContent("An argument");
    await fireEvent.keyDown(textbox(), { key: "z", ctrlKey: true });
    expect(textbox().querySelector("em")).toBeNull();
    await fireEvent.keyDown(textbox(), { key: "z", ctrlKey: true, shiftKey: true });
    expect(textbox().querySelector("em")).toHaveTextContent("An argument");
  });

  it.each([
    ["Bulleted list", "ul", "- An argument"],
    ["Numbered list", "ol", "1. An argument"]
  ])("applies and removes a %s with the toolbar", async (name, tag, markdown) => {
    const onChange = vi.fn();
    render(MarkdownEditor, { label, value: "An argument", onChange });
    instance().commands.selectAll();
    const button = screen.getByRole("button", { name });
    await fireEvent.click(button);
    expect(textbox().querySelector(`${tag} li`)).toHaveTextContent("An argument");
    expect(onChange).toHaveBeenLastCalledWith(markdown);
    expect(button).toHaveAttribute("aria-pressed", "true");
    await fireEvent.click(button);
    expect(textbox().querySelector(tag)).toBeNull();
    expect(onChange).toHaveBeenLastCalledWith("An argument");
  });

  it("applies a heading and returns it to a paragraph", async () => {
    const onChange = vi.fn();
    render(MarkdownEditor, { label, value: "Introduction", onChange });
    instance().commands.selectAll();
    const style = screen.getByRole("combobox", { name: "Draft text style" });
    await fireEvent.change(style, { target: { value: "2" } });
    expect(within(textbox()).getByRole("heading", { level: 2 })).toHaveTextContent("Introduction");
    expect(onChange).toHaveBeenLastCalledWith("## Introduction");
    await fireEvent.change(style, { target: { value: "0" } });
    expect(textbox().querySelector("p")).toHaveTextContent("Introduction");
    expect(onChange).toHaveBeenLastCalledWith("Introduction");
  });

  it.each(["- First", "1. First"])("continues a list on Enter and exits an empty item: %s", async (value) => {
    render(MarkdownEditor, { label, value });
    instance().commands.focus("end");
    await fireEvent.keyDown(textbox(), { key: "Enter" });
    expect(textbox().querySelectorAll("li")).toHaveLength(2);
    await fireEvent.keyDown(textbox(), { key: "Enter" });
    expect(textbox().querySelectorAll("li")).toHaveLength(1);
    expect(textbox().lastElementChild?.tagName).toBe("P");
  });

  it("keeps rich-text undo across a view switch", async () => {
    render(MarkdownEditor, { label, value: "Original" });
    instance().commands.selectAll();
    await fireEvent.click(screen.getByRole("button", { name: "Bold" }));
    await fireEvent.click(toggle());
    expect(textbox()).toHaveValue("**Original**");
    await fireEvent.click(toggle());
    await fireEvent.click(screen.getByRole("button", { name: "Undo" }));
    expect(textbox().querySelector("strong")).toBeNull();
    expect(textbox()).toHaveTextContent("Original");
  });

  it("loads external replacements without emitting edits or retaining old-document undo", async () => {
    const onChange = vi.fn();
    const { rerender } = render(MarkdownEditor, { label, value: "First essay", onChange });
    instance().commands.selectAll();
    await fireEvent.click(screen.getByRole("button", { name: "Bold" }));
    onChange.mockClear();
    await rerender({ label, value: "# Another essay", onChange });
    expect(within(textbox()).getByRole("heading", { name: "Another essay" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Undo" })).toBeDisabled();
    expect(onChange).not.toHaveBeenCalled();
  });

  it("resets undo when a different document has identical Markdown", async () => {
    const { rerender } = render(MarkdownEditor, { label, value: "Same text", documentKey: "first" });
    instance().commands.selectAll();
    await fireEvent.click(screen.getByRole("button", { name: "Bold" }));
    await fireEvent.click(screen.getByRole("button", { name: "Bold" }));
    expect(screen.getByRole("button", { name: "Undo" })).toBeEnabled();
    await rerender({ label, value: "Same text", documentKey: "second" });
    expect(textbox()).toHaveTextContent("Same text");
    expect(screen.getByRole("button", { name: "Undo" })).toBeDisabled();
  });

  it("disables formatting and both editing modes while unavailable", async () => {
    const onChange = vi.fn();
    const { rerender } = render(MarkdownEditor, { label, value: "Draft", onChange });
    await rerender({ label, value: "Draft", disabled: true, onChange });
    expect(textbox()).toHaveAttribute("contenteditable", "false");
    expect(toggle()).toBeDisabled();
    expect(screen.getByRole("button", { name: "Bold" })).toBeDisabled();
    await rerender({ label, value: "Draft", disabled: false, onChange });
    await fireEvent.click(toggle());
    await rerender({ label, value: "Draft", disabled: true, onChange });
    expect(textbox()).toBeDisabled();
    expect(onChange).not.toHaveBeenCalled();
  });

  it.each([
    "| A | B |\n| - | - |\n| C | D |",
    "![Diagram](diagram.png)",
    "- [ ] Task",
    "<!-- keep this comment -->\n\nAn essay"
  ])("preserves unsupported Markdown in source mode: %s", async (value) => {
    const onChange = vi.fn();
    render(MarkdownEditor, { label, value, onChange });
    expect(textbox()).toHaveValue(value);
    expect(screen.getByRole("status")).toHaveTextContent("raw Markdown editing to preserve it");
    expect(toggle()).toBeDisabled();
    expect(onChange).not.toHaveBeenCalled();
    await fireEvent.input(textbox(), { target: { value: "Now **supported**" } });
    expect(toggle()).toBeEnabled();
    await fireEvent.click(toggle());
    expect(textbox().querySelector("strong")).toHaveTextContent("supported");
  });

  it("detects unsupported syntax typed in raw mode and allows repair", async () => {
    render(MarkdownEditor, { label, value: "Plain text" });
    await fireEvent.click(toggle());
    await fireEvent.input(textbox(), { target: { value: "![Keep this](picture.png)" } });
    expect(toggle()).toBeDisabled();
    expect(textbox()).toHaveValue("![Keep this](picture.png)");
    await fireEvent.input(textbox(), { target: { value: "Repaired" } });
    await fireEvent.click(toggle());
    expect(textbox()).toHaveAttribute("contenteditable", "true");
    expect(textbox()).toHaveTextContent("Repaired");
  });

  it("destroys the editor when unmounted", async () => {
    const { unmount } = render(MarkdownEditor, { label, value: "Draft" });
    const editor = instance();
    await unmount();
    await waitFor(() => expect(editor.isDestroyed).toBe(true));
  });
});

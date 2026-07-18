import { fireEvent, render, screen, waitFor } from "@testing-library/svelte";
import { beforeEach, describe, expect, it, vi } from "vitest";
import App from "./App.svelte";

type MockResponse = {
  ok: boolean;
  status: number;
  json: () => Promise<unknown>;
};

function jsonResponse(status: number, data: unknown): MockResponse {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => data
  };
}

function getDisplayNameInput(container: HTMLElement): HTMLElement & { value: string } {
  const input = container.querySelector("sl-input") as HTMLElement & { value: string } | null;
  if (!input) {
    throw new Error("Display name input not found");
  }
  return input;
}

function getCreateAccountActionButton(): HTMLElement {
  const createButtons = screen.getAllByText("Create Account");
  const actionButton = createButtons[1];
  if (!actionButton) {
    throw new Error("Create Account action button not found");
  }
  return actionButton;
}

describe("App account login flow", () => {
  beforeEach(() => {
    localStorage.clear();
    vi.restoreAllMocks();
  });

  it("shows login gate with available accounts when logged out", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(
        jsonResponse(200, [
          { accountId: { unAccountId: "alice" }, displayName: "Alice", preferredModel: "llama3.1:8b" },
          { accountId: { unAccountId: "bob" }, displayName: "Bob", preferredModel: null }
        ])
      );

    vi.stubGlobal("fetch", fetchMock);

    render(App);

    expect(await screen.findByText("Welcome to Essaying")).toBeInTheDocument();
    expect(await screen.findByText("Alice")).toBeInTheDocument();
    expect(screen.getByText("Bob")).toBeInTheDocument();
    expect(fetchMock).toHaveBeenCalledWith("/api/v1/accounts");
  });

  it("logs into an account and logs out back to login screen", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue(
        jsonResponse(200, [
          { accountId: { unAccountId: "alice" }, displayName: "Alice", preferredModel: "llama3.1:8b" }
        ])
      )
    );

    render(App);

    const loginButton = await screen.findByText("Alice");
    await fireEvent.click(loginButton);

    expect(await screen.findByText("Essaying Workbench")).toBeInTheDocument();
    expect(screen.getByText(/Logged in as Alice/)).toBeInTheDocument();
    expect(localStorage.getItem("essay-account-id")).toBe("alice");

    await fireEvent.click(screen.getByText("Log Out"));
    expect(await screen.findByText("Welcome to Essaying")).toBeInTheDocument();
    expect(localStorage.getItem("essay-account-id")).toBeNull();
  });

  it("creates an account and logs in on success", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(jsonResponse(200, []))
      .mockResolvedValueOnce(
        jsonResponse(201, {
          accountId: { unAccountId: "charlie" },
          displayName: "Charlie",
          preferredModel: "llama3.1:8b"
        })
      );

    vi.stubGlobal("fetch", fetchMock);

    const { container } = render(App);

    await screen.findByText("Welcome to Essaying");

    const displayNameInput = getDisplayNameInput(container);

    displayNameInput.value = "Charlie";
    await fireEvent(
      displayNameInput,
      new CustomEvent("sl-input", {
        bubbles: true,
        composed: true
      })
    );

    await fireEvent.click(getCreateAccountActionButton());

    await waitFor(() => {
      expect(fetchMock).toHaveBeenNthCalledWith(
        2,
        "/api/v1/accounts",
        expect.objectContaining({
          method: "POST"
        })
      );
    });

    expect(await screen.findByText("Essaying Workbench")).toBeInTheDocument();
    expect(screen.getByText(/Logged in as Charlie/)).toBeInTheDocument();
    expect(localStorage.getItem("essay-account-id")).toBe("charlie");
  });

  it("shows duplicate-account error on 409 create response", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(jsonResponse(200, []))
      .mockResolvedValueOnce(jsonResponse(409, { message: "exists" }));

    vi.stubGlobal("fetch", fetchMock);

    const { container } = render(App);

    await screen.findByText("Welcome to Essaying");

    const displayNameInput = getDisplayNameInput(container);

    displayNameInput.value = "Alice";
    await fireEvent(
      displayNameInput,
      new CustomEvent("sl-input", {
        bubbles: true,
        composed: true
      })
    );

    await fireEvent.click(getCreateAccountActionButton());

    expect(await screen.findByText(/Could not create account: Error: That account already exists\./)).toBeInTheDocument();
    expect(screen.getByText("Welcome to Essaying")).toBeInTheDocument();
  });
});

import { fireEvent, render, screen, waitFor } from "@testing-library/svelte";
import { beforeEach, describe, expect, it, vi } from "vitest";
import App from "./App.svelte";

type ApiResponse = {
  status: number;
  data: unknown;
};

function jsonResponse(status: number, data: unknown): ApiResponse {
  return {
    status,
    data
  };
}

function emptyWorkspaceResponse(): ApiResponse {
  return jsonResponse(200, { tree: [] });
}

function responseFromApiResponse(response: ApiResponse): Response {
  return new Response(JSON.stringify(response.data), {
    status: response.status,
    headers: {
      "Content-Type": "application/json"
    }
  });
}

function createApiAwareFetchMock(apiResponses: ApiResponse[]) {
  let nextApiResponseIndex = 0;

  return vi.fn((input: RequestInfo | URL) => {
    const url = typeof input === "string" ? input : input.toString();

    if (url.includes("/workspace/context")) {
      return Promise.resolve(responseFromApiResponse(jsonResponse(404, { error: { message: "Context does not exist." } })));
    }

    if (url.startsWith("/api/")) {
      const response = apiResponses[nextApiResponseIndex] ?? jsonResponse(500, { message: "Unexpected API call" });
      nextApiResponseIndex += 1;
      return Promise.resolve(responseFromApiResponse(response));
    }

    return Promise.resolve(new Response("", { status: 200 }));
  });
}

function apiCalls(fetchMock: { mock: { calls: Array<[RequestInfo | URL, RequestInit?]> } }) {
  return fetchMock.mock.calls.filter(([input]) => {
    const url = typeof input === "string" ? input : input.toString();
    return url.startsWith("/api/");
  });
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
    vi.spyOn(window, "confirm").mockReturnValue(true);
  });

  it("shows login gate with available accounts when logged out", async () => {
    const fetchMock = createApiAwareFetchMock([
      jsonResponse(200, [
        { accountId: { unAccountId: "alice" }, displayName: "Alice", preferredModel: "llama3.1:8b" },
        { accountId: { unAccountId: "bob" }, displayName: "Bob", preferredModel: null }
      ])
    ]);

    vi.stubGlobal("fetch", fetchMock);

    render(App);

    expect(await screen.findByText("Welcome to Essaying")).toBeInTheDocument();
    expect(await screen.findByText("Alice")).toBeInTheDocument();
    expect(screen.getByText("Bob")).toBeInTheDocument();
    expect(fetchMock).toHaveBeenCalledWith("/api/v1/accounts");
  });

  it("logs into an account and logs out back to login screen", async () => {
    const fetchMock = createApiAwareFetchMock([
      jsonResponse(200, [
        { accountId: { unAccountId: "alice" }, displayName: "Alice", preferredModel: "llama3.1:8b" }
      ]),
      emptyWorkspaceResponse()
    ]);

    vi.stubGlobal("fetch", fetchMock);

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

  it("renders nested folders and selects the active essay in the workspace tree", async () => {
    localStorage.setItem("essay-account-id", "alice");
    const fetchMock = createApiAwareFetchMock([
      jsonResponse(200, [
        { accountId: { unAccountId: "alice" }, displayName: "Alice", preferredModel: null }
      ]),
      jsonResponse(200, {
        tree: [
          {
            name: "History",
            path: ["History"],
            nodeType: "WorkspaceDirectoryNode",
            children: [
              {
                name: "French Revolution",
                path: ["History", "French Revolution"],
                nodeType: "WorkspaceDirectoryNode",
                children: [
                  {
                    name: "Notes",
                    path: ["History", "French Revolution", "Notes"],
                    nodeType: "WorkspaceEssayNode",
                    children: []
                  }
                ]
              }
            ]
          }
        ]
      }),
      jsonResponse(200, {
        path: ["History", "French Revolution", "Notes"],
        title: "Notes",
        prompt: "", markdown: "# Notes"
      }),
      jsonResponse(200, {
        path: ["History", "French Revolution", "Notes"],
        title: "Notes",
        prompt: "", markdown: "# Updated notes"
      })
    ]);

    vi.stubGlobal("fetch", fetchMock);
    const { container } = render(App);

    const historyItem = await waitFor(() => {
      const item = container.querySelector('sl-tree-item[data-path="[\\"History\\"]"]');
      expect(item).not.toBeNull();
      return item as HTMLElement;
    });
    const essayItem = container.querySelector(
      'sl-tree-item[data-path="[\\"History\\",\\"French Revolution\\",\\"Notes\\"]"]'
    );
    expect(essayItem).not.toBeNull();
    expect(historyItem).toHaveAttribute("expanded");
    expect(essayItem).toHaveAttribute("selected");
    expect(essayItem?.parentElement).toBe(
      container.querySelector('sl-tree-item[data-path="[\\"History\\",\\"French Revolution\\"]"]')
    );

    const editor = Array.from(container.querySelectorAll<HTMLElement & { label: string; value: string; updateComplete: Promise<boolean> }>("sl-textarea")).find((element) => element.label === "Essay Markdown") as (HTMLElement & { value: string }) | null;
    if (!editor) {
      throw new Error("Essay editor not found");
    }
    editor.value = "# Updated notes";
    await fireEvent(editor, new CustomEvent("sl-input", { bubbles: true, composed: true }));
    await fireEvent.click(screen.getByText("Save Draft"));

    await waitFor(() => {
      const saveCall = apiCalls(fetchMock).find(([input, init]) => {
        const url = typeof input === "string" ? input : input.toString();
        return url.endsWith("/workspace/essays/History/French%20Revolution/Notes") && init?.method === "PUT";
      });
      expect(saveCall).toBeDefined();
      expect(JSON.parse(String(saveCall?.[1]?.body))).toEqual({ markdown: "# Updated notes" });
    });
    expect(await screen.findByText("Draft saved for History/French Revolution/Notes")).toBeInTheDocument();
  });

  it.each(["mrroww", ""])("clears the editor after loading and editing an essay starting with %j", async (initialMarkdown) => {
    localStorage.setItem("essay-account-id", "alice");
    const populatedPath = ["meow", "meoww"];
    const emptyPath = ["meow", "meow in", "Empty Essay"];
    const fetchMock = createApiAwareFetchMock([
      jsonResponse(200, [
        { accountId: { unAccountId: "alice" }, displayName: "Alice", preferredModel: null }
      ]),
      jsonResponse(200, {
        tree: [{
          name: "meow", path: ["meow"], nodeType: "WorkspaceDirectoryNode",
          children: [
            { name: "meoww", path: populatedPath, nodeType: "WorkspaceEssayNode", children: [] },
            {
              name: "meow in", path: ["meow", "meow in"], nodeType: "WorkspaceDirectoryNode",
              children: [{ name: "Empty Essay", path: emptyPath, nodeType: "WorkspaceEssayNode", children: [] }]
            }
          ]
        }]
      }),
      jsonResponse(200, { path: populatedPath, title: "meoww", prompt: "", markdown: initialMarkdown }),
      jsonResponse(200, { path: emptyPath, title: "Empty Essay", prompt: "", markdown: "" }),
      jsonResponse(200, { path: emptyPath, title: "Empty Essay", prompt: "", markdown: "" })
    ]);
    vi.stubGlobal("fetch", fetchMock);
    const { container } = render(App);
    const editor = await waitFor(() => {
      const element = Array.from(container.querySelectorAll<HTMLElement & { label: string; value: string; updateComplete: Promise<boolean> }>("sl-textarea")).find((element) => element.label === "Essay Markdown") as
        (HTMLElement & { value: string; updateComplete: Promise<boolean> }) | null;
      expect(element?.value).toBe(initialMarkdown);
      return element!;
    });

    const emptyItem = await waitFor(() => {
      const item = Array.from(container.querySelectorAll("sl-tree-item"))
        .find((item) => item.getAttribute("data-path") === JSON.stringify(emptyPath));
      expect(item).toBeDefined();
      return item!;
    });
    editor.value = "mrroww";
    await fireEvent(editor, new CustomEvent("sl-input", { bubbles: true, composed: true }));
    await fireEvent(container.querySelector("sl-tree")!, new CustomEvent("sl-selection-change", {
      detail: { selection: [emptyItem] }, bubbles: true
    }));

    await screen.findByText("Currently editing meow/meow in/Empty Essay.");
    await waitFor(() => expect(editor.value).toBe(""));
    await editor.updateComplete;
    expect(editor.shadowRoot?.querySelector("textarea")).toHaveValue("");

    await fireEvent.click(screen.getByText("Save Draft"));
    await waitFor(() => {
      const saveCall = apiCalls(fetchMock).find(([, init]) => init?.method === "PUT");
      expect(saveCall?.[0]).toBe("/api/v1/accounts/alice/workspace/essays/meow/meow%20in/Empty%20Essay");
      expect(JSON.parse(String(saveCall?.[1]?.body))).toEqual({ markdown: "" });
    });
  });

  it("creates an account and logs in on success", async () => {
    const fetchMock = createApiAwareFetchMock([
      jsonResponse(200, []),
      jsonResponse(201, {
        accountId: { unAccountId: "charlie" },
        displayName: "Charlie",
        preferredModel: "llama3.1:8b"
      }),
      emptyWorkspaceResponse()
    ]);

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
      expect(
        apiCalls(fetchMock).some(
          ([input, init]) => input === "/api/v1/accounts" && init?.method === "POST"
        )
      ).toBe(true);
    });

    expect(await screen.findByText("Essaying Workbench")).toBeInTheDocument();
    expect(screen.getByText(/Logged in as Charlie/)).toBeInTheDocument();
    expect(localStorage.getItem("essay-account-id")).toBe("charlie");
  });

  it("shows duplicate-account error on 409 create response", async () => {
    const fetchMock = createApiAwareFetchMock([
      jsonResponse(200, []),
      jsonResponse(409, { message: "exists" })
    ]);

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

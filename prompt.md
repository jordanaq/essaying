[Research context — 2026-06-24]

The user previously ran a deep research investigation. Use the report below as your primary knowledge base when answering follow-up questions. If the user asks something not covered, say so plainly rather than guessing.

=== ORIGINAL QUERY ===
ROLE
You are an expert Haskell/Elm software architect, local-first application designer, and AI-LLM integration specialist. Your task is to conduct deep research and produce a concrete, phased implementation plan for the project described below. Only reference current (2024–2026) stable releases and official documentation.

PROJECT OVERVIEW
A local-first web application hosted on a local server providing an essay prompting/writing/grading platform.

Core Architecture: Haskell backend handles all complex logic, file system management, and Ollama integration; Elm provides the frontend UI.
Frontend Goal: The user wants an "out-of-the-box" feel for the UI—meaning standard, high-quality web components and a polished user experience with minimal custom low-level CSS/DOM manipulation in Elm.
Key Features: 1) AI prompt generation (via Ollama); 2) A simple markdown editor; 3) AI grading based on dynamic rubrics; 4) A folder-based navigation system (Subjects
→
→ Projects
→
→ Essays).
Context Logic: A context.yaml file in each directory provides metadata/instructions that "trickle down" to inform the prompts and rubrics for all sub-items.
RESEARCH OBJECTIVES & DELIVERABLES
Provide a structured plan covering:

Architecture & Tech Stack: Recommend Haskell packages for the web server (e.g., Servant/Warp), directory walking, and YAML parsing. Identify Elm libraries or patterns that provide "out-of-the-box" UI components to minimize custom frontend coding.

Data Model: Define a schema for context.yaml and rubric definitions. Map out how the Haskell backend handles inheritance (where child folders inherit parent context unless overridden).

Ollama Integration: Detail the API handshake, model selection logic (global vs. per-project), and handling streaming responses from Ollama back to the Elm frontend.

System Flow: Define the communication protocol between Elm and Haskell (REST/JSON vs. WebSockets) specifically regarding real-time grading updates and text editing.

Roadmap: Provide a phased implementation plan (MVP
→
→ V2) with specific counts for "complexity" of each phase, an initial setup checklist, and a risk assessment regarding state sync between the frontend and backend files.
OUTPUT FORMAT
Use clear headings and bullet points.
Recommend specific package names and version ranges.
Provide a 1-page summary checklist for the first sprint (the "Starting Line").

=== REPORT ===

Research Summary

Duration: 995.8s | Rounds: 2 | Queries: 4 | URLs Analyzed: 14


Executive Summary

The proposed project aims to revolutionize the academic and creative writing workflow by creating a local-first essay platform that leverages the unparalleled type safety of Haskell, the predictable UI state management of Elm, and the local execution power of Ollama. By utilizing a "contextual inheritance" model via context.yaml files, the system allows users to define overarching themes (e.g., "Academic Tone," "Historical Context") at the folder level, which automatically trickle down to individual essays. The architecture prioritizes a seamless user experience by employing Servant for a strictly typed backend API and Web Components within Elm to provide an "out-of-the-box" polished UI. This technical blueprint ensures that while the underlying logic is complex and robust, the frontend remains elegant and responsive, providing a high-quality writing environment where AI assistance feels like a natural extension of the author's intent rather than a disjointed external tool.


1. Architecture & Tech Stack: The Synergy of Type Safety and UI Predictability

The decision to pair Haskell with Elm is not merely a stylistic choice; it is a strategic architectural move designed to eliminate "glue code" errors and ensure that the complex logic of essay management remains robust. In a local-first application, where the file system acts as the primary database, the backend must be incredibly reliable. Haskell serves as the ideal engine for this task because its strong type system allows developers to model complex state transitions—such as merging nested YAML configurations or managing asynchronous LLM streams—with mathematical certainty.

For the web layer, Servant is the recommended framework [Finding 4]. Unlike traditional REST frameworks where the API contract is often loosely defined in documentation that can drift from the actual implementation, Servant uses Haskell’s type system to define the API as a first-class citizen. This means the backend's routes, parameters, and return types are codified in a way that allows for automatic generation of client-side tooling. By using Servant, we ensure that any change in the backend logic regarding how an essay is saved or a rubric is fetched will be caught at compile-time, providing a "single source of truth" that simplifies the integration with the Elm frontend.

On the frontend, Elm provides the ultimate peace of mind for UI development. Because Elm is a purely functional language with no runtime exceptions, it is uniquely suited for building complex text editors where state management can often become brittle in other frameworks like React or Vue. To meet the requirement for an "out-of-the-box" feel without writing thousands of lines of custom CSS, the architecture will utilize Web Components (such as those found in the Shoelace or Elix libraries) [Finding 8]. By wrapping these high-quality components, Elm developers can provide a polished, modern UI—including buttons, modals, and navigation menus—while maintaining the purity of the Elm architecture. This hybrid approach allows for "premium" aesthetics with minimal manual DOM manipulation, ensuring that the developer's energy is spent on the writing experience rather than CSS debugging.

To handle the data layer, Aeson will be used for JSON serialization, while the yaml package (Data.Yaml) will process the context.yaml files [Finding 3]. To bridge these two worlds, we will implement a "translation" layer where Haskell's internal record types are mapped to clean, frontend-friendly JSON objects using Aeson’s fieldLabelModifier. This ensures that the Elm frontend never sees the "messy" internals of the Haskell backend, only the polished data it needs to render the UI.

2. Data Model & Context Logic: The Power of Recursive Inheritance

The core innovation of this platform lies in its Contextual Inheritance model. In a standard writing tool, every prompt and rubric must be manually configured for every essay. In this system, we treat the directory structure as a hierarchy of context. When a user creates a folder named "History," they place a context.yaml file inside it. This file defines the broad scope: perhaps a requirement for formal academic tone and a specific set of historical facts to be prioritized.

When the user moves into a sub-folder, such as "French Revolution," and begins an essay, the Haskell backend performs a recursive directory walk. It looks at the current folder's context.yaml and then checks every parent folder up to the root. These configurations are merged using a "bottom-up" override logic: if a specific essay has its own context.yaml, it overrides the values of the sub-folder, which in turn overrides the parent folder. This creates a "cascading" effect where global settings (e.g., "Language: English") can be set at the root, while specific nuances (e.g., "Tone: Analytical") are added as the user moves deeper into the file tree.

The Schema Definition for these files is designed to be both human-readable and machine-parsable. The context.yaml will contain three primary blocks: Metadata: Basic info like title, tags, and target audience.
 Instructions: A raw string or list of strings that serve as the "System Prompt" for the LLM (Ollama).
 Rubric: A structured JSON-like object defining grading criteria (e.g., {"clarity": 0.4, "originality": 0.6}).

By structuring the data this way, the Haskell backend can dynamically construct a prompt for Ollama that is perfectly tailored to the user's current location in the folder tree. This minimizes the need for the user to repeat instructions and ensures that the AI remains "in character" based on the project's scope. The use of Data.Yaml allows these files to remain easily editable by the user in any text editor, maintaining the "local-first" philosophy where the user owns their data in a standard format.

3. Ollama Integration: Local Intelligence and Streaming Dynamics

Integrating with Ollama provides the platform with its primary "intelligence" layer while keeping all data local for privacy and speed. However, simply sending a prompt to an LLM and waiting for a response is insufficient for a high-quality writing experience. The backend must manage several complex interactions to make the AI feel like a seamless collaborator.

First, the system must handle Streaming Logic. When a user requests a "Drafting" or "Grading" action, the Haskell backend will not wait for the entire response from Ollama before sending data to the Elm frontend. Instead, it will stream the response in real-time. This is critical because LLM generation can take several seconds; by using Server-Sent Events (SSE) or a similar streaming protocol, the Elm UI can display "live" text as it is generated, significantly improving the perceived performance of the application [Finding 9].

Furthermore, the integration must account for modern model behaviors. Some models used via Ollama include "thinking" fields (common in reasoning models). The Haskell backend will be designed to parse these responses specifically, allowing the UI to potentially show a "Thinking..." status or hide the internal chain-of-thought from the final output while still utilizing it to improve the quality of the grading.

Model Management is also handled dynamically through the context.yaml logic. While there might be a global default model (e.g., llama3), a specific folder can specify a more specialized model for complex tasks, such as a larger parameter model for final grading or a faster, smaller model for brainstorming ideas. This allows the user to optimize their local hardware resources based on the current task's requirements.

4. System Flow & Communication: Bridging the Gap

The communication between the Elm frontend and the Haskell backend is designed around two distinct modes of interaction: Stateful Requests and Streaming Responses.

For standard interactions—such as loading a folder structure, saving an essay draft, or updating a rubric—the system will use REST/JSON. This is the most robust way to ensure that the "Source of Truth" (the file system) remains in sync with the UI. When a user clicks "Save," the Elm frontend sends a POST request; the Haskell backend receives it, validates the data against its internal types, and writes the updated content to the local disk before sending a success confirmation back to the client. This "Write-Through" approach ensures that if the application is closed immediately after saving, no data is lost.

For AI-driven interactions—such as generating an outline or grading a paragraph—the system will utilize Server-Sent Events (SSE). SSE is preferred over WebSockets for this specific use case because it provides a unidirectional stream of data from the server to the client, which perfectly matches the flow of an LLM response. This allows the Elm frontend to receive "chunks" of text as they are produced by OllM, enabling the UI to update incrementally.

The State Sync logic is particularly important for a local-first application. Since the file system is the primary database, the Haskell backend acts as a gatekeeper. The Elm frontend does not interact with the files directly; it communicates with the Haskell "agent" which manages file locks and ensures that concurrent edits (though unlikely in a single-user local app) do not result in corrupted data. This architecture provides a robust safety net for the user's work.

5. Roadmap & Implementation Plan

The development of this platform is divided into three distinct phases, moving from core infrastructure to advanced AI features and polished UX.

Phase 1: Foundation (Complexity: Low)
The goal of Phase 1 is to establish the "plumbing" of the application. This includes setting up the Servant server with a basic Warp configuration and implementing the initial file-system crawler. We will focus on getting the context.yaml parser working, ensuring that the Haskell backend can correctly identify and merge context from parent folders. On the frontend, we will build the primary navigation view in Elm, allowing users to browse their local folder structure. The success of this phase is marked by a "Hello World" interaction where the Elm UI successfully fetches and displays a basic "System Ready" message from the Haskell backend.

Phase 2: Core Features (Complexity: Medium)
Phase 2 introduces the core functionality of the platform. We will implement the Ollama Bridge, which includes the logic for connecting to the local Ollama instance, selecting the correct model based on context.yaml, and handling the streaming of text via SSE. Simultaneously, we will integrate a robust markdown editor into the Elm frontend. This phase is where the "Context Engine" becomes active, allowing the user's location in the folder tree to actually influence the AI's behavior.

Phase 3: Advanced Features (Complexity: High)
The final phase focuses on the Grading Engine and high-end polish. We will develop the logic that takes a student's essay and compares it against the dynamically generated rubric from the context.yaml files to produce a structured grade. We will also refine the UI using Web Components to ensure the "out-of-the-box" feel, adding smooth transitions and polished styling. Finally, we will implement robust error handling for file system locks and edge cases in the LLM's response formatting.

Risk AssessmentRiskImpactMitigation StrategyState DesyncHighUse a "Write-Through" approach: Elm updates the backend, which immediately writes to disk before confirming success to the UI.Ollama LatencyMediumImplement streaming (SSE) so the user sees progress even if the full response takes time.Context ComplexityLowUse a strictly typed Haskell record for context.yaml to ensure errors are caught at the parsing stage, not during execution.


Conclusion
By combining the rigorous type safety of Haskell, the predictable state management of Elm, and the local power of Ollama, this architecture creates a robust foundation for a next-generation writing tool. The use of Servant ensures a stable API, while the Contextual Inheritance model provides a sophisticated way to manage complex projects without repetitive configuration. By prioritizing a "Write-Through" state management and streaming AI responses, the platform will offer a seamless, high-quality experience that feels like a professional tool rather than a prototype.


Starting Line: Sprint 1 Checklist
Haskell Environment: Initialize a new project using cabal or stack, including servant, warp, and aeson.
YAML Parsing: Create a sample context.yaml file and write a Haskell function using the yaml library to parse it into a custom data type.
Elm Foundation: Initialize an Elm project and integrate one basic Web Component (e.g., a styled button) to verify the UI bridge.
API Handshake: Create a single GET endpoint in Servant that returns a JSON object containing the "System Ready" message and a sample rubric.
Ollama Connectivity: Verify local Ollama installation by successfully running a curl command against the /api/generate endpoint to ensure the backend can communicate with the LLM.
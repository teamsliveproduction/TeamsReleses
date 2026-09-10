# Microsoft Teams Samples

A curated collection of code samples for building Microsoft Teams applications using the **Teams SDK**. Each sample targets a specific capability and is available in multiple languages.

## Samples

| Sample | Description | Languages |
|--------|-------------|-----------|
| [Agent Targeted Messages](samples/TeamsSDK/agent-targeted-messages/README.md) | Reminder agent that sends targeted messages visible only to a specific user in a shared channel or group chat | TypeScript, C#, Python |
| [Bot Auth Quickstart](samples/TeamsSDK/bot-auth-quickstart/README.md) | SSO authentication for Teams bots using Azure Active Directory and Microsoft Graph | TypeScript, C#, Python |
| [Bot Task Modules](samples/TeamsSDK/bot-task-modules/README.md) | Task modules (dialogs) in Teams bots — Adaptive Cards, custom HTML forms, and multi-step dialogs | TypeScript, C#, Python |
| [Tab + Add-in Combined](samples/tab-add-in-combined/nodejs/README.md) | Single app combining a Teams Tab with an Outlook Add-in to manage discount offers across both surfaces | TypeScript |

## Prerequisites

- A [Microsoft 365 developer account](https://docs.microsoft.com/microsoftteams/platform/concepts/build-and-test/prepare-your-o365-tenant) or a Teams account with app-upload permissions
- [DevTunnels](https://learn.microsoft.com/azure/developer/dev-tunnels/get-started) (or ngrok) for local development
- Language runtimes as required by the sample:
  - [Node.js](https://nodejs.org/) (TypeScript samples)
  - [.NET SDK](https://dotnet.microsoft.com/download) (C# samples)
  - [Python](https://www.python.org/downloads/) (Python samples)

## Getting Started

1. Clone the repository:
   ```bash
   git clone https://github.com/OfficeDev/Microsoft-Teams-Samples.git
   ```
2. Navigate to the sample directory you want to run.
3. Follow the setup instructions in that sample's `README.md`.

## Frameworks & Tools

- [Microsoft Teams SDK](https://microsoft.github.io/teams-sdk/) — TypeScript, C#, and Python packages
- [Teams Developer CLI](https://microsoft.github.io/teams-sdk/cli/) — provision apps, bots, and AAD registrations from the command line
- [Teams Developer Portal](https://dev.teams.microsoft.com) — manage manifests, bots, and app packages

## Further Reading

- [Microsoft Teams Platform Documentation](https://learn.microsoft.com/microsoftteams/platform/)
- [Teams SDK Documentation](https://microsoft.github.io/teams-sdk/)
- [Microsoft Graph API](https://developer.microsoft.com/graph)

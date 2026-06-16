# Onboarding Plan

## Pillar
Cross-cutting (Tenancy & Accounts)

## Status
Active — building now.

## Current Reality

- A fresh open-source install bootstraps the first sign-in as the platform admin and auto-creates a personal org named from the email local-part (e.g. `nauman`) — a rough default the user shouldn't be stuck with.
- Empty resource lists (servers/apps) render as blank tables with no guidance.
- There is no guided first-run; a new operator lands on an empty dashboard with no next step.

## Goal

Make the first five minutes obvious for someone who just cloned and deployed Conductor: name your organization, understand what to do next, and add your first server — without reading docs.

## Scope

- **Name your org first-run.** New orgs start un-onboarded (`organizations.onboarded_at` is null). Until completed, the user is routed to a welcome screen to name the org (and confirm) before using the app.
- **Helpful empty states.** Servers and Apps indexes show a "Get started" card (what it is, the one action to take) instead of an empty table.
- **Next-step guidance.** After naming the org, a short checklist points to "Add a server" → "Add an app".

## Non-goals

- A multi-step wizard that provisions servers automatically (that's provider automation).
- Forcing data entry beyond the org name.
- Product tour/coachmarks library.

## Core Workflows

1. **First run.** First user signs in → bootstraps as admin with an un-onboarded org → redirected to `/onboarding`.
2. **Name org.** User submits an org name → `onboarded_at` set → redirected to the dashboard with a "what's next" checklist.
3. **Empty states.** Visiting Servers/Apps with none shows a clear CTA to add the first one.
4. **Returning users.** Onboarded orgs never see the welcome screen again.

## Data Model

- `organizations.onboarded_at : datetime` (null = needs onboarding).
- `Organization#onboarded?` → `onboarded_at.present?`.

## Routes / Controllers

- `OnboardingController#show` (welcome + name form), `#update` (set name + `onboarded_at`).
- `ApplicationController` redirects authenticated users with an un-onboarded current org to `/onboarding` (excluding the onboarding and sign-out paths).

## Verification (test-first)

- New org is `onboarded? == false`; completing onboarding sets `onboarded_at` and renames the org.
- An un-onboarded user hitting any page is redirected to `/onboarding`.
- After onboarding, the user reaches the dashboard and is not redirected again.
- Empty Servers/Apps indexes render the "Get started" CTA.

## Mockup

`docs/plans/mockups/onboarding.html` — open in a browser to review the welcome screen, empty states, and the next-step checklist.

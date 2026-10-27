#!/usr/bin/env python3
"""Experiment: emit an unsigned plain .shortcut (no trigger) that runs the iBoard capture intent.
Usage: make_experiment.py out.shortcut   (then: shortcuts sign -m anyone -i out -o signed)
The AppIntent action layout is UNVERIFIED against a real export (see docs/ONBOARDING.md)."""
import plistlib, sys, uuid

action = {
    "WFWorkflowActionIdentifier": "app.iBoard.CaptureVerificationCodeIntent",
    "WFWorkflowActionParameters": {
        "AppIntentDescriptor": {
            "TeamIdentifier": "",
            "BundleIdentifier": "app.iBoard",
            "Name": "iBoard",
            "AppIntentIdentifier": "CaptureVerificationCodeIntent",
        },
        "UUID": str(uuid.uuid4()),
    },
}
wf = {
    "WFWorkflowClientVersion": "4000",
    "WFWorkflowMinimumClientVersion": 900,
    "WFWorkflowMinimumClientVersionString": "900",
    "WFWorkflowIcon": {"WFWorkflowIconStartColor": 463140863, "WFWorkflowIconGlyphNumber": 59511},
    "WFWorkflowTypes": [],
    "WFWorkflowInputContentItemClasses": ["WFStringContentItem"],
    "WFWorkflowActions": [action],
    "WFWorkflowImportQuestions": [],
}
with open(sys.argv[1], "wb") as f:
    plistlib.dump(wf, f, fmt=plistlib.FMT_BINARY)

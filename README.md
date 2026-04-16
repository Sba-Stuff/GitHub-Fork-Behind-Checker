# GitHub Fork Behind Checker

[![PowerShell Version](https://img.shields.io/badge/PowerShell-5.1+-blue.svg)](https://github.com/PowerShell/PowerShell)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A PowerShell script that scans all repositories of a GitHub user, identifies forked repositories, and calculates how many commits they are behind their upstream source.

## 📋 Description

This tool helps you maintain your GitHub forks by identifying which repositories have fallen behind their original source. It automatically:

- Discovers all public repositories for a given GitHub username
- Identifies which repositories are forks
- Fetches commit counts
- Calculates how many commits each fork is behind its source
- Exports results to a CSV file for easy analysis

Perfect for developers who maintain multiple forks and need to keep them synchronized with upstream changes.

## ✨ Features

- ✅ **Robust HTML parsing** – handles extra whitespace and HTML tags between numbers and text
- ✅ **Automatic pagination** – discovers all repositories, even those across multiple pages
- ✅ **Fork detection** – identifies upstream source repositories
- ✅ **CSV export** – easy to import into Excel, Google Sheets, or other tools
- ✅ **Progress indicators** – shows real-time progress during execution
- ✅ **Error handling** – gracefully skips failed repositories and continues

## 🚀 Getting Started

### Prerequisites

- **PowerShell 5.1** or higher (Windows) or **PowerShell Core** (macOS/Linux)
- Internet connection to access GitHub
- No authentication required – works with public repositories only

### Installation

1. **Clone this repository**

```bash
git clone https://github.com/Sba-Stuff/github-fork-behind-checker.git
cd github-fork-behind-checker
GFBC.bat
```

2. Enter Your Github User ID to check all forked repos and comits behind..

3. All data saved in CSV.

4. Open and check upto date forked repos that requires updates and sync.


### `LICENSE` (MIT License)

```text
MIT License

Copyright (c) 2026 Sba Stuff

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

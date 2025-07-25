#!/usr/bin/env node

const { execSync } = require('child_process');
const { readFileSync } = require('fs');
const https = require('https');

// Configuration
const API_KEY = process.env.API_KEY;
const API_USER = process.env.API_USER;
const EVENT_NAME = process.env.GITHUB_EVENT_NAME;
const PR_BASE_SHA = process.env.PR_BASE_SHA;
const PR_HEAD_SHA = process.env.PR_HEAD_SHA;

const DEPLOY = EVENT_NAME === 'push';

// Validate PR has only one commit
function validateSingleCommit() {
  if (DEPLOY) return; // GitHub branch protections disallow merge commits

  const commitCount = execSync(`git rev-list --count ${PR_BASE_SHA}..${PR_HEAD_SHA}`, { encoding: 'utf8' }).trim();

  if (parseInt(commitCount) !== 1) {
    console.error(`❌ PR must contain exactly 1 commit, found ${commitCount}`);
    console.error('Please squash your commits before merging');
    process.exit(1);
  }

  console.log('✅ PR contains exactly 1 commit');
}

// Get file changes from the single commit
function getFileChanges() {
  const updates = {};

  // Get added/modified files from HEAD commit
  const changedFiles = execSync('git diff --name-only --diff-filter=AM HEAD~1 HEAD', { encoding: 'utf8' })
    .trim().split('\n').filter(Boolean)
    .filter(path => { return !path.startsWith('.') && path.includes('/'); });

  for (const file of changedFiles) {
    try {
      updates[file] = readFileSync(file, 'utf8');
    } catch (error) {
      console.error(`Could not read ${file}:`, error.message);
      process.exit(1);
    }
  }

  // Get deleted files from HEAD commit
  const deletedFiles = execSync('git diff --name-only --diff-filter=D HEAD~1 HEAD', { encoding: 'utf8' })
    .trim().split('\n').filter(Boolean)
    .filter(path => { return !path.startsWith('.') && path.includes('/'); });

  for (const file of deletedFiles) {
    updates[file] = null; // null indicates deletion
  }

  return updates;
}

// Helper function to create PUT options for a file
function createPutOptions(file, content) {
  const path = require('path').dirname(file);
  if (path !== "site_texts") {
    console.error(`❌ The admin config /${path}/ is not currently supported`);
    process.exit(1);
  }
  const filename = require('path').basename(file, require('path').extname(file));
  const url = `https://discourse.julialang.org/admin/customize/${path}/${filename}`;

  const { URLSearchParams } = require('url');
  const params = new URLSearchParams();
  params.append('site_text[value]', content);
  params.append('site_text[locale]', 'en');
  const payload = params.toString();

  const urlObj = new URL(url);
  return {
    url,
    options: {
      hostname: urlObj.hostname,
      path: urlObj.pathname,
      method: 'PUT',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
        'Accept': '*/*',
        'Api-Key': API_KEY,
        'Api-Username': API_USER
      }
    },
    payload
  };
}

// Send updates to external API or print dry run
function sendUpdates(updates) {
  const fileCount = Object.keys(updates).length;
  if (fileCount === 0) {
    console.log('No file changes detected');
    return;
  }
  console.log(`\n🔍 Sending ${fileCount} updates:`);
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');

  for (const [file, content] of Object.entries(updates)) {
    if (content === null) {
      console.error(`⚠️  Skipping deletion of ${file} (not supported)`);
      process.exit(1);
    }

    const { url, options, payload } = createPutOptions(file, content);

    console.log(`📝 UPDATE: ${file} → ${url}`);
    console.log(`   PUT ${url}`);
    console.log(`   Body: ${payload}\n`);
    if (DEPLOY) {
      // Actual API calls for main branch

      const req = https.request(options, (res) => {
        if (res.statusCode >= 200 && res.statusCode < 300) {
            console.log(`✅ Updated ${file} → ${url} (HTTP ${res.statusCode})`);
        } else {
            console.error(`❌ Failed to update ${file}: HTTP ${res.statusCode}`);
            process.exit(1);
        }
      });

      req.on('error', (error) => {
        console.error(`❌ Failed to update ${file}: ${error.message}`);
        process.exit(1);
      });

      req.write(payload);
      req.end();
    }
  }
}

// Main execution
console.log(`🚀 Running in ${DEPLOY ? 'LIVE' : 'DRY RUN'} mode`);

validateSingleCommit();
const updates = getFileChanges();
sendUpdates(updates);

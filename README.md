# Confluence-Hudu-Migration

Easily transfer your Confluence pages over to Hudu!

---

# Getting Started

## Prerequisites

Ensure you have:

- Hudu instance ready to go with your API key on-hand (version 2.37.1 or newer required)
- Confluence instance ready to transfer with API key on-hand, associated username (email)
- Powershell 7.5.0 or later is reccomended for running this script

## Starting

It's reccomended to instantiate via dot-sourcingl, ie

```
. .\Confluence-Migration.ps1
```

It will load HuduAPI powershell module
- locally if present in this folder: "C:\Users\$env:USERNAME\Documents\GitHub\HuduAPI\HuduAPI\HuduAPI.psm1"
- otherwise from Powershell Gallery

A few folders will be created for logging/debug and images

<img width="862" alt="image" src="https://github.com/user-attachments/assets/a81459eb-336e-44cd-8c73-56c8765017d7" />

You'll then be prompted to enter:
- `HuduBaseURL` - this is the url to your hudu instance, e.g urinstance.huducloud.com
- `HuduAPIKey`
- `ConfluenceDomain` - e.g 'hudu-integrations' would be valid for 'https://www.hudu-integrations.atlassian.net'
- `ConfluenceAPIkey`

After entering these, your credentials are verified and encoded and we verify you are on a sufficient Hudu version.

## Setup

If you plan on migrating articles to individual companies, you'll want to first create those companies in Hudu, so they can be attributed as you like.

You'll be asked just a few questions- firstly, source space(s) for your confluence articles.
You can decide to:
- migrate pages to Hudu from a single space
- migrate pages to Hudu from all spaces

Now, the html bodies of your confluence articles, attachments, will be parsed, have their links spat out. 
you can enter 1 to proceed (no going back) or enter 2 for this question to go back and start over

<img width="1435" alt="image" src="https://github.com/user-attachments/assets/0ee34fa5-34b8-4192-b636-fc317bc8a1a2" />

This is mostly useful if your articles are blank or have an issue, to verify that the contents and links are present.

Next, you'll be asked about where to migrate these articles.
You can decide to:
- migrate these all to global/central KB (non-company-specific)
- migrate these all to a single company
- decide each time per-article

If you selected to decide each time per-article, you'll then choose one of the following for each page/article based on the page title and page preview-
-to associate page/article with any given company
-leave it as a central/global kb article
-skip article/page migration

<img width="1530" alt="image" src="https://github.com/user-attachments/assets/c6d006c2-e3c4-4f01-9f31-f1dd1c83fe59" />

## Main Migration

### Step 1: Stubbing Articles
Article stubs will be created so we can correlate Hudu Article id's later. If you chose to decide on where to migrate articles on a per-article basis, you are shown a sample of each article and decide which companies (or central kb) to migrate these to. At this point, articles will just contain a 'preview' of the article bodies.

<img width="1204" alt="image" src="https://github.com/user-attachments/assets/e635fdd9-493f-4df9-89ec-9e580f0c00ca" />

### Step 2: Attachments

Attached files and embeds will now be uploaded and attributed to the new articles. If any files are larger than 100mb, they will be skipped, more on this later.
All images, including .gif, .bmp, svg will be uploaded and associated with their respective articles. Common image formats are uplaoded as 'public_photos' in Hudu, while other image formats are uploaded as 'uploads' in Hudu. both will still be embedded in your articles, however, and links will be retained.
exe, zip, tar.xz, anything goes and will be uploaded/attributed so long as it is under 100mb

<img width="1111" alt="image" src="https://github.com/user-attachments/assets/ee369278-e061-40fb-955b-a9ab3796029e" />

### Step 3: Article Bodies for Embeds/Attachments

Article bodies are modified to include the new attachment / embed urls in Hudu. Some confluence-specific stuff is stripped out here and we update the articles

<img width="802" alt="image" src="https://github.com/user-attachments/assets/6dcf9bfc-1168-404e-8431-1acf5fb76c77" />

# Step 4: Relinking

Articles at this stage are modified to change links between confluence articles to links between Hudu articles. This part can take a while depending on how many articles/links are present. We match each article to all possible links that had been from confluence to their new Hudu equivilent.
<img width="1096" alt="image" src="https://github.com/user-attachments/assets/f8407df3-d41a-42fb-98f4-e7b9fd0cff76" />
There's:
- self links
- edit links
- webui links
- webui v2 links
- tinyui links
- api request links
- edit links
- versioning links
- css class links / TOC links
- extenal links
and based on your confluence page metadata, these are replaced with the equivilent link in hudu (except external links). 

# Step 5: Wrap up- At this point, the script is finished! Sign into Hudu and verify that inter-linked articles, images, uploads, attachments are all good (they should be).

## Main Logfile

Your Main log file can be found in `logs\ConfluenceTransfer.log`

<img width="592" alt="image" src="https://github.com/user-attachments/assets/5f639aba-e436-4e4d-b91b-742e253c7b2a" />

You will also have a summary json file in the same folder, named `job-summary.json`, which includes any brief messages about articles you skipped, attachments that were too large, or any other issues otherwise. It also includes some handy at-a-glance info about our 

migration results, including some that are related to, but not limited to the following:

- links found / created / replaced
- articles found / created / skipped / errored
- attachments / uploads created / found / skipped due to size
- warnings or errors
- articles that were too large
- your hudu version
- your powershell version

<img width="551" alt="image" src="https://github.com/user-attachments/assets/a96ba0e5-534c-48f0-b097-bc41aa0bf01e" />

It will be written out for reference, but you can also use this file to help others track down any problems.

## Tmp dir and files

Before/After html files from your pages are saved in `.\tmp` as raw before/after html files

<img width="302" alt="image" src="https://github.com/user-attachments/assets/0bc036f0-da4b-4c1d-a5b6-8ed654b5945d" />

you can also find some of the pages and their metadata in `.\tmp`, which are handy for correlating events or issues

<img width="347" alt="image" src="https://github.com/user-attachments/assets/c098a97a-b47d-4f18-90b4-f3158e32e93e" />

you'll also find totality of your attachments, images, files here in `tmp`

## Errored objects/tasks

errors or data that wasnt accepted such as files that were larger than 100mb can be found in `.\logs\errored` and will be named after the task/file/issue. 
This is handy for checking for any errors at a glance and taking action

### Todo/thoughts
It might be neat to incorporate some of the other non-pages / non-article data in this migration

# Disclaimer

This PowerShell script is provided "as-is" without any warranties or guarantees, express or implied. The authors and Hudu Technologies make no guarantees regarding the accuracy, reliability, or suitability of the script for any purpose.

By using this script, you acknowledge that you do so at your own risk. The authors and Hudu Technologies shall not be liable for any damages, losses, or issues that may arise from its use, including but not limited to data loss, system failures, or security breaches. Always review the code thoroughly and test it in a safe environment before deploying it in a production setting.



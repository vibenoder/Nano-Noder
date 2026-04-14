# Nano-Noder
Easy &amp; Fast setup of Nano Node + User-Friendly Representative Account Setup + Web Dashboard (nanonoder.com)

Even Users with just very basic Linux knowledge can run a Nano Node (Even Rep Node) with this tool. Beginner friendly

Get a new Linux Server with Ubuntu OS.  
Login to your terminal via SSH.  
Paste this single line into the terminal and hit ENTER button:

    curl -sL https://raw.githubusercontent.com/vibenoder/Nano-Noder/main/Nano-Node.sh | bash

   
The above single command executes the entire script.  
It runs the latest version of Nano Node + Fast Sync.  
It will also save you nearly 90+ hours of sync time and avoids 4TB or Disk IO usage during bootstrapping.  
This also installs a live dashboard tool for your Nano Node that you can run with a simple command. 


Depending on your system specs, your Full sync'd Nano Node will be up and running in under 20 minutes.

# What this script automatically does:
1. Updates Linux packages
2. Installs tools (required for comprehensive node details displayed at nanonoder.com)
3. Odometer Setup (To check Cumulative Uptime of the Node)
4. Downloads and extracts latest Ledger Snapshot (using Aria tool for fast download)
5. Installs and runs Nano Node in a docker container
6. Creates short user-friendly commands for users to check node status
7. Friendly yet very informative Representative Account Setup
8. Strict system checks to ensure the server is capable of running Representative node
9. Informs users every step so they avoid mistakes and ensures their node can start voting


After complete auto installation and running of the node, to see a live dashboard of the node, just type:

    dashboard

To setup Representative account easily, exit the dashboard and just type:

    rep


# System Specs for observer Node
To run a normal Nano Node, below is the minimum System Specs required:

CPU: 4 Cores  
RAM: 6 GB  
Disk: SSD    
Storage: 400 GB available disk space  
Internet Speed: 160 Mbps up/down (20 MB/s)


# System specs for Representative Node
To run a Representative Node, below is the minimum System Specs required:

CPU: 4+ Cores  
RAM: 12 GB (16 GB for Principle Representative)  
Disk: SSD (NVME Preferred)  
Storage: 500 GB available disk space
Internet Speed: 400 Mbps up/down (50 MB/s)  


More more info, please visit nanonoder.com


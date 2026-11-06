# **Juliet Case Study**







### **TLDR:**



**T**o set up the binaries and your container, run:

&#x09;**./setup.sh**



**To analyze all programs in one swoop, run:**

&#x09;**./oneShot.sh**







### **File Directory:**

* **src:** The Juliet test cases in C. **DO NOT TOUCH THESE**.
* **support:** Extra files that the test cases depend on. **DO NOT TOUCH THESE**.
* **Containerfile**: Required to create your image with buildah.
* **build.sh:** Compiles every C program in src into a **bin** directory.
* **check.sh:** Uses clang to analyze a given file. Deposits report into a **reports** directory.
* **analysis.sh:** Takes a directory as an input and runs every C file through check.sh.
* **setup.sh:** Simply runs build.sh in your image using podman.
* **oneShot.sh:** Essentially runs analysis.sh in your image using podman. 












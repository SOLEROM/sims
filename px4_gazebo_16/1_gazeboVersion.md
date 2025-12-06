# gazebo versions


# ✅ There are *two different Gazebo families* in the world right now

You saw **Gazebo Classic** and **Gazebo (Ignition/Harmonic)** — these are *not* different versions of the same program; they are **two separate simulator architectures**.

Let’s break them down.

---

# 🟦 1. Gazebo Classic (a.k.a. gazebo, gazebo11)

**Package name on Ubuntu:** `gazebo` / `gazebo11`
**Binary:** `gazebo`
**PX4 target:** `gazebo-classic`
**Age:** ~10+ years old
**Status:** **Legacy / maintenance only**

## ✔ Characteristics

* Monolithic C++ application.
* GUI + physics engine + plugins all in one big program.
* XML worlds (`.world` files) with SDF version <= 1.6.
* Plugins written for Classic do **not** work in Ignition/Harmonic.

## ✔ Advantages

* Mature, stable, used for years in robotics & PX4.
* Tons of models, plugins, documentation.
* Works well with PX4 1.11–1.14 and ArduPilot.

## ❌ Limitations

* Architecture became hard to maintain.
* Slow development, physics engines outdated.
* GUI not modular.
* No modern rendering pipelines (Vulkan).
* Dropped as the primary PX4 simulator on Ubuntu 22.04.

## 🔍 Summary

**Classic = older, stable, big monolithic simulator.**
Still works, but not future-proof.

---

# 🟩 2. Gazebo Ignition ➜ Gazebo (Harmonic) (a.k.a. gz sim)

**Package names:**

* `gz-sim8`, `gz-gui8`, `gz-rendering8`, etc.
  **Binary:** `gz sim`
  **PX4 target:** `gz_*` (example: `make px4_sitl_default gz_x500`)
  **Age:** ~5 years
  **Status:** **Actively developed, default PX4 simulator on Ubuntu 22.04**

## ✔ Characteristics

* **Modular architecture**:

  * gz-physics
  * gz-rendering
  * gz-sim
  * gz-gui
* Each component is standalone and versioned independently.
* More modern SDF spec (1.7+).
* Uses modern rendering (OGRE2, soon Vulkan).
* Designed for cloud simulation, containers, modular plugins.

## ✔ Advantages

* Much cleaner API and plugin system.
* Better physics engines (DART, Bullet, soon PhysX).
* Faster rendering and shader pipelines.
* Scales better for multi-robot and cloud usage.
* Fully supported in PX4 **1.15+** onwards
* Official simulator for ROS2, PX4, and new robotics frameworks.

## ❌ Limitations

* Not all old Classic models/plugins are compatible.
* Some Classic worlds must be rewritten.
* Documentation still improving.
* GUI is Qt-based and sometimes heavy in containers.

## 🔍 Summary

**Ignition/Harmonic = modern, modular, future-focused Gazebo.**
Actively maintained and used by PX4 moving forward.

---

# 🚀 Why PX4 1.16 on Ubuntu 22.04 uses `gz sim` instead of Classic

### ✔ Classic (gazebo11) **is no longer packaged natively** in Ubuntu 22.04

Ubuntu removed `gazebo11` from Jammy repos. PX4 can still force-install it from OSRF repos, but support is weak.

### ✔ PX4’s official simulator moving forward is Gazebo Harmonic (`gz sim`)

PX4 team switched to Harmonic/GZ as the main supported sim starting around v1.14–1.15.

### ✔ Better for containers / cloud / multi-robot

GZ’s modular libraries isolate rendering, physics, transport — easier to containerize.

### ✔ Classic plugins are deprecated

The `gazebo-classic` target builds old plugins, but they won’t get new features.

---

# 🆚 Side-by-side comparison table

| Feature              | Gazebo Classic (`gazebo`)  | Gazebo Harmonic (`gz sim`)            |
| -------------------- | -------------------------- | ------------------------------------- |
| Age                  | Old (10+ yrs)              | New (modern architecture)             |
| Packaging            | `gazebo11`, `libgazebo11`  | `gz-sim8`, `gz-gui8`, `gz-rendering8` |
| PX4 support          | Legacy                     | Official + full support               |
| GUI                  | Monolithic                 | Modular Qt GUI                        |
| Rendering            | OGRE1                      | OGRE2, Vulkan-ready                   |
| Multi-robot          | Weak                       | Strong                                |
| Cloud / Containers   | Hard                       | Designed for it                       |
| Plugin compatibility | **Not compatible** with GZ | **Not compatible** with Classic       |
| Future               | Maintenance only           | Active development                    |

---

# 🧠 TL;DR

### **Gazebo Classic**

* Old, monolithic simulator (`gazebo` binary)
* Still works, but being phased out
* PX4 Classic integration exists but not preferred

### **Gazebo Harmonic (Ignition / GZ)**

* New-generation simulator (`gz sim`)
* Much more modular and powerful
* Official PX4 simulator for Ubuntu 22.04+
* What you are now using in your Docker

---

If you want, I can also:

✅ Draw an architecture diagram comparing Classic vs GZ
✅ Compare PX4 plugin flow for both versions
✅ Show how HITL differs between Classic and GZ
✅ Explain when to choose Classic over GZ for drone projects

Just tell me!

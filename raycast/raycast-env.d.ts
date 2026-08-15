/// <reference types="@raycast/api">

/* 🚧 🚧 🚧
 * This file is auto-generated from the extension's manifest.
 * Do not modify manually. Instead, update the `package.json` file.
 * 🚧 🚧 🚧 */

/* eslint-disable @typescript-eslint/ban-types */

type ExtensionPreferences = {
  /** socktainerctl Executable - Optional absolute path to socktainerctl. Standard install locations are detected automatically. */
  "controlExecutable"?: string
}
/** Preferences accessible in all the extension's commands */
declare type Preferences = ExtensionPreferences

declare namespace Preferences {
  /** Preferences accessible in the `socktainer` command */
  export type Socktainer = ExtensionPreferences & {}
}

declare namespace Arguments {
  /** Arguments passed to the `socktainer` command */
  export type Socktainer = {}
}

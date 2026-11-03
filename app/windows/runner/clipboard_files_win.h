#ifndef RUNNER_CLIPBOARD_FILES_WIN_H_
#define RUNNER_CLIPBOARD_FILES_WIN_H_

#include <string>
#include <vector>

// [FORK] 读取剪贴板里的「文件列表」。
//
// 在资源管理器里 Ctrl+C 一个文件/多个文件时，剪贴板里放的是 CF_HDROP
// （一组绝对路径），**不是**位图。所以「复制一张 .jpg 再粘贴」走不到
// 图片通道里来，必须单独处理文件列表。
//
// 返回 UTF-8 的绝对路径；剪贴板里没有文件时返回空。
std::vector<std::string> ReadClipboardFilePathsUtf8();

#endif  // RUNNER_CLIPBOARD_FILES_WIN_H_

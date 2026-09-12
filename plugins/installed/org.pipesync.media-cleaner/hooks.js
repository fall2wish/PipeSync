(() => {
  const finalQueue = [];
  for (const item of PipeContext.files) {
    if (item.name.endsWith(".tmp") || item.name.startsWith(".")) {
      PipeContext.utils.log(`Discarding transient file: ${item.name}`);
      continue;
    }
    const formattedDate = PipeContext.utils.formatDate(item.lastModifiedMs, "yyyy-MM-dd");
    finalQueue.push({
      sourcePath: item.path,
      targetRelativePath: `${formattedDate}/${item.name}`
    });
  }
  return finalQueue;
})();
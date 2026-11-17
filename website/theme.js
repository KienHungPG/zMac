// Đặt giao diện sáng / tối đã chọn trước khi trang hiện ra, để không bị chớp màu.
// Nạp đồng bộ trong <head> vì CSP không cho script viết thẳng trong HTML.
try {
  const t = localStorage.getItem('theme');
  if (t === 'light' || t === 'dark') document.documentElement.dataset.theme = t;
} catch { /* localStorage bị chặn: theo hệ thống */ }

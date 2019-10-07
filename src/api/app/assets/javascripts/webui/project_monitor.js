function setAllLinks(event) {
  $(this).closest('.dropdown-menu').find('input').prop('checked', event.data.checked);
}

function statusCell(meta, statusHash, tableInfo, projectName, packageName) {
  var info = tableInfo[meta.col - 1];
  var repository = info[0];
  var architecture = info[1];
  var status = statusHash[repository][architecture][packageName] || {};
  var code = status.code;
  var cellContent = {};
  if (code === undefined) return null;

  var klass = 'build-state-' + code;
  var output = '<a ';
  if (['succeeded', 'failed', 'building', 'finished', 'signing'].includes(code)) {
    var url = '/package/live_build_log/' + projectName + '/' + packageName + '/' + repository + '/' + architecture;
    output += 'href="' + url + '"';
  } else {
    var id = meta.row + '-' + meta.col;
    output += 'href="javascript:void(0);" id="' + id + '"';

    if (status.details !== undefined) {
      if (code === 'scheduled') klass = 'text-warning';
      output += ' data-content="' + status.details + '" data-placement="right" data-toggle="popover"';
    }
  }
  output += ' class="' + klass + '">' + code + '</a>';

  cellContent.display = output;
  cellContent.value = code;

  return cellContent;
}

function initializeMonitorDataTable() {
  var data = $('tbody').data();
  var packageNames = data.packagenames;
  var statusHash = data.statushash;
  var tableInfo = data.tableinfo;
  var projectName = data.project;

  initializeDataTable('#project-monitor-table', { // jshint ignore:line
    scrollX: true,
    fixedColumns: true,
    pageLength: 50,
    lengthMenu: [[10, 25, 50, 100, -1], [10, 25, 50, 100, "All"]],
    data: packageNames,
    search: {
      regex: true,
      smart: false,
    },
    columnDefs: [
      {
        width: 150,
        targets: 0,
        className: 'text-left',
        data: null,
        render: function (packageName) {
          var url = '/package/show/' + projectName + '/' + packageName;
          return '<a href="' + url + '">' + packageName + '</a>';
        }
      },
      {
        targets: '_all',
        data: null,
        className: 'text-center',
        render: function (packageName, type, row, meta) {
          var cellContent = statusCell(meta, statusHash, tableInfo, projectName, packageName);
          if (cellContent === null) return null;
          // Value to display in the cell
          if (type === 'display') return cellContent.display;
          // Value to sort or filter by
          return cellContent.value;
        }
      }
    ]
  });
}

function setupProjectMonitor() { // jshint ignore:line
  initializeMonitorDataTable();

  $('#table-spinner').addClass('d-none');
  $('#project-monitor .obs-dataTable').removeClass('invisible');

  $('#filter-button').on('click', function () {
    $('#table-spinner').removeClass('d-none');
  });

  $('#project-monitor-table').on('draw.dt', function () {
    initializePopovers('[data-toggle="popover"]'); // jshint ignore:line
  });

  initializePopovers('[data-toggle="popover"]'); // jshint ignore:line

  $('.monitor-no-filter-link').on('click', { checked: false }, setAllLinks);

  $('.monitor-filter-link').on('click', { checked: true }, setAllLinks);

  $('.dropdown-menu.keep-open').on('click', function (e) {
    e.stopPropagation();
  });
}
